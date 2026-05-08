//
//  FeudBuzzerView.swift
//  OpenMDict-iOS
//
//  Cherry-red dome on a chrome cylinder — the iconic Family Feud
//  contestant buzzer that gets slapped to ring in. We only show the
//  dome + a slice of the cylinder (the rest disappears below the
//  podium in the broadcast set, and we don't have the vertical room
//  for a full cylinder anyway). Perspective is 3/4-overhead so the
//  dome is rendered as a flattened ellipse rather than a circle.
//
//  Drawn into a UIImage at first layout (cached, no continuous CALayer
//  cost), with a touchDown scale transform for tactile feedback.
//

import UIKit

@available(iOS 26, *)
final class FeudBuzzerView: UIControl {

    // MARK: - Subviews

    private let imageView = UIImageView()
    private var cachedImageSize: CGSize = .zero

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 225, height: 170)
    }

    private func setupViews() {
        backgroundColor = .clear

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Press feedback: bottom-anchored compression. The dome
        // (top of image) moves DOWN + flattens slightly while the
        // cylinder bottom stays put, so visually the button gets
        // pressed INTO the metal pipe — instead of the whole buzzer
        // shrinking around its center, which read as "shrink in
        // place" rather than "press down".
        //
        // Math: scale Y around the layer's default center anchor pulls
        // the bottom UP by `bounds.h/2 × (1-sy)`. We translate Y back
        // down by the same amount so the bottom returns to its frame
        // position, which leaves only the top half visibly compressing.
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let scaleX: CGFloat = 0.97
            let scaleY: CGFloat = 0.92
            let bottomCompensation = self.imageView.bounds.height / 2 * (1 - scaleY)
            UIView.animate(withDuration: 0.08) {
                self.imageView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
                    .concatenating(CGAffineTransform(translationX: 0, y: bottomCompensation))
            }
        }, for: .touchDown)
        let restore = UIAction { [weak self] _ in
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.45,
                initialSpringVelocity: 0.6
            ) {
                self?.imageView.transform = .identity
            }
        }
        addAction(restore, for: .touchUpInside)
        addAction(restore, for: .touchUpOutside)
        addAction(restore, for: .touchCancel)
    }

    // MARK: - Layout

    /// Asset catalog name for the buzzer PNG. If present, used in
    /// preference to the procedural `renderBuzzer(size:)` fallback —
    /// procedurally faking a glossy plastic button never quite reaches
    /// "晶莹剔透" in practice. Drop a PNG into
    /// `Assets.xcassets/PhraseFeudButton.imageset/` to switch.
    private static let assetName = "PhraseFeudButton"

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != cachedImageSize {
            cachedImageSize = bounds.size
            // Prefer the PNG asset when it ships; fall back to the
            // procedural renderer so the build is never blank if the
            // asset hasn't been dropped in yet.
            if let png = UIImage(named: Self.assetName) {
                imageView.image = png
            } else {
                imageView.image = Self.renderBuzzer(size: bounds.size)
            }
        }
    }

    // MARK: - Rendering

    /// Renders the buzzer as: cylinder drawn FIRST (it stretches all
    /// the way to the bottom of the view; the caller positions the
    /// view past the screen edge so the cylinder appears cropped),
    /// then the dome ON TOP — wider than the cylinder and overlapping
    /// its lip by 15pt, so the cylinder's actual top edge is hidden
    /// behind the dome's "skirt".
    private static func renderBuzzer(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Fixed dome geometry — does NOT scale with view height.
            // The cylinder absorbs all extra height, so taller views
            // just show more cylinder (the part that gets cropped off
            // when the view extends past view.bottom).
            //
            // Dome aspect ~2.3:1 (size.width × 98). Cylinder top is
            // positioned 14pt up inside the dome's bottom rim so the
            // dome's "skirt" overhangs the cylinder. Cylinder is
            // proportionally narrower (cylinder width / view width
            // ratio is smaller than before): the dome was widened 50%
            // while the cylinder only widened 20%, so the dome's
            // overhang past the cylinder is more pronounced — reads as
            // a beefy mushroom-cap on a slimmer stem.
            let domeHeight: CGFloat = 98
            let domeOverlap: CGFloat = 14
            let cylinderInsetRatio: CGFloat = 0.278

            let domeRect = CGRect(x: 0, y: 0, width: size.width, height: domeHeight)
            let cylinderInset = size.width * cylinderInsetRatio
            let cylinderTop = domeHeight - domeOverlap
            let cylinderRect = CGRect(
                x: cylinderInset,
                y: cylinderTop,
                width: size.width - 2 * cylinderInset,
                height: size.height - cylinderTop
            )

            // ====================================================
            // CYLINDER BODY — refined 7-stop chrome gradient. Bright /
            // dark / mid stripes evoke a polished metal cylinder with
            // multiple light reflections (lab/studio overhead lighting).
            // ====================================================
            cg.saveGState()
            cg.addRect(cylinderRect)
            cg.clip()
            let chromeColors = [
                UIColor(white: 0.40, alpha: 1).cgColor,  // far-left edge shadow
                UIColor(white: 0.72, alpha: 1).cgColor,
                UIColor(white: 0.96, alpha: 1).cgColor,  // primary specular
                UIColor(white: 0.78, alpha: 1).cgColor,
                UIColor(white: 0.50, alpha: 1).cgColor,  // mid shadow band
                UIColor(white: 0.85, alpha: 1).cgColor,  // secondary highlight
                UIColor(white: 0.42, alpha: 1).cgColor,  // far-right edge shadow
            ]
            let chromeLocations: [CGFloat] = [0, 0.16, 0.32, 0.48, 0.64, 0.82, 1]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: chromeColors as CFArray,
                locations: chromeLocations
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: cylinderRect.minX, y: 0),
                    end: CGPoint(x: cylinderRect.maxX, y: 0),
                    options: []
                )
            }
            cg.restoreGState()

            // ====================================================
            // CYLINDER RIM — cel-shaded zones, but each zone has an
            // internal subtle gradient (not pure solid color) so the
            // ring reads as a polished chrome curve rather than a
            // flat sticker. Highlight is offset to the LEFT (light
            // source comes from upper-left) for asymmetric realism.
            // ====================================================
            let rimHeight: CGFloat = 24
            let rimRect = CGRect(
                x: cylinderRect.minX,
                y: domeHeight - rimHeight / 2,
                width: cylinderRect.width,
                height: rimHeight
            )
            cg.saveGState()
            cg.addEllipse(in: rimRect)
            cg.clip()

            // Base: mid gray (no internal gradient, just fills the
            // visible portion of the ellipse)
            cg.setFillColor(UIColor(white: 0.32, alpha: 1).cgColor)
            cg.fill(rimRect)

            // Shadow band — top of rim. Asymmetric horizontal gradient
            // (slightly darker on the right where light doesn't reach).
            let rimShadowRect = CGRect(
                x: rimRect.minX,
                y: rimRect.minY - 2,
                width: rimRect.width,
                height: rimRect.height * 0.55
            )
            cg.saveGState()
            cg.addEllipse(in: rimShadowRect)
            cg.clip()
            let rimShadowColors = [
                UIColor(white: 0.18, alpha: 1).cgColor,
                UIColor(white: 0.06, alpha: 1).cgColor,
            ]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: rimShadowColors as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: rimShadowRect.minX, y: 0),
                    end: CGPoint(x: rimShadowRect.maxX, y: 0),
                    options: []
                )
            }
            cg.restoreGState()

            // Highlight band — offset LEFT (catches the upper-left
            // light source). Internal horizontal gradient: bright in
            // the middle, fading to mid-tone at the edges.
            let rimHighlightRect = CGRect(
                x: rimRect.minX + rimRect.width * 0.04,
                y: rimRect.midY + 2,
                width: rimRect.width * 0.70,  // narrower + offset left
                height: rimRect.height * 0.45
            )
            cg.saveGState()
            cg.addEllipse(in: rimHighlightRect)
            cg.clip()
            let rimHighlightColors = [
                UIColor(white: 0.55, alpha: 1).cgColor,
                UIColor(white: 0.92, alpha: 1).cgColor,
                UIColor(white: 0.65, alpha: 1).cgColor,
            ]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: rimHighlightColors as CFArray,
                locations: [0, 0.45, 1]
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: rimHighlightRect.minX, y: 0),
                    end: CGPoint(x: rimHighlightRect.maxX, y: 0),
                    options: []
                )
            }
            cg.restoreGState()

            cg.restoreGState()

            // ====================================================
            // DOME — cel-shading FRAMEWORK (discrete zones with hard
            // boundaries between them) + per-zone INTERNAL gradients
            // (so each zone reads as glossy plastic, not flat sticker)
            // + ASYMMETRIC positioning (light source is upper-left,
            // not directly above — matches real-world reflection).
            //
            // Layers, all clipped to the dome ellipse:
            //   (1) base mid-red fill
            //   (2) shadow zone with internal linear gradient
            //   (3) lit zone with internal linear gradient (asym left)
            //   (4) specular hot spot with radial gradient (asym left)
            // ====================================================
            cg.saveGState()
            cg.addEllipse(in: domeRect)
            cg.clip()

            // (1) Base — mid red, fills full silhouette
            cg.setFillColor(UIColor(red: 0.82, green: 0.08, blue: 0.08, alpha: 1).cgColor)
            cg.fill(domeRect)

            // (2) Shadow zone — ellipse offset DOWN with internal
            //     diagonal gradient (upper-left edge slightly lighter
            //     than lower-right corner — light bleeds in from the
            //     same side as the highlight).
            let domeShadowRect = CGRect(
                x: 4,
                y: domeRect.height * 0.30,
                width: domeRect.width - 8,
                height: domeRect.height * 0.85
            )
            cg.saveGState()
            cg.addEllipse(in: domeShadowRect)
            cg.clip()
            let shadowColors = [
                UIColor(red: 0.55, green: 0.05, blue: 0.05, alpha: 1).cgColor,
                UIColor(red: 0.25, green: 0.0,  blue: 0.0,  alpha: 1).cgColor,
            ]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: shadowColors as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: domeShadowRect.minX, y: domeShadowRect.minY),
                    end:   CGPoint(x: domeShadowRect.maxX, y: domeShadowRect.maxY),
                    options: []
                )
            }
            cg.restoreGState()

            // (3) Lit zone — ellipse offset UP and slightly LEFT.
            //     Internal diagonal gradient: bright pink-red at upper-
            //     left, fading to mid-red at lower-right. Asymmetric
            //     placement + asymmetric gradient direction = realistic
            //     directional lighting from upper-left.
            let domeLitRect = CGRect(
                x: 4,                             // bias slightly left
                y: -(domeRect.height * 0.06),
                width: domeRect.width - 24,       // narrower (asym, more on right)
                height: domeRect.height * 0.55
            )
            cg.saveGState()
            cg.addEllipse(in: domeLitRect)
            cg.clip()
            let litColors = [
                UIColor(red: 0.99, green: 0.55, blue: 0.50, alpha: 1).cgColor,  // upper-left bright
                UIColor(red: 0.92, green: 0.22, blue: 0.20, alpha: 1).cgColor,
                UIColor(red: 0.78, green: 0.08, blue: 0.08, alpha: 1).cgColor,  // lower-right
            ]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: litColors as CFArray,
                locations: [0, 0.55, 1]
            ) {
                cg.drawLinearGradient(
                    g,
                    start: CGPoint(x: domeLitRect.minX, y: domeLitRect.minY),
                    end:   CGPoint(x: domeLitRect.maxX, y: domeLitRect.maxY),
                    options: []
                )
            }
            cg.restoreGState()

            // (4) Specular hot spot — small soft glow with RADIAL
            //     gradient (white center → transparent edges) so the
            //     "wet" hotspot has a soft falloff. Positioned upper-
            //     LEFT (not centered) — the bright reflection of the
            //     upper-left light source.
            let specCenter = CGPoint(
                x: domeRect.width * 0.36,         // upper-left, off-center
                y: domeRect.height * 0.22
            )
            let specRadius = domeRect.width * 0.22
            cg.saveGState()
            cg.addEllipse(in: domeRect)
            cg.clip()
            let specColors = [
                UIColor(white: 1, alpha: 0.92).cgColor,
                UIColor(white: 1, alpha: 0.50).cgColor,
                UIColor(white: 1, alpha: 0.0).cgColor,
            ]
            if let g = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: specColors as CFArray,
                locations: [0, 0.45, 1]
            ) {
                cg.drawRadialGradient(
                    g,
                    startCenter: specCenter,
                    startRadius: 0,
                    endCenter: specCenter,
                    endRadius: specRadius,
                    options: []
                )
            }
            cg.restoreGState()

            cg.restoreGState()
        }
    }
}
