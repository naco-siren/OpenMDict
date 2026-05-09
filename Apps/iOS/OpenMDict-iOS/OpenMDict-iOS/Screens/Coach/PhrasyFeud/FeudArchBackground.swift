//
//  FeudArchBackground.swift
//  OpenMDict-iOS
//
//  Stage backdrop. Pure black with a dense gold-dot pattern tiled across
//  it; a double-bordered top-arch curve drawn as TWO STROKE LAYERS
//  (outer dark brown + inner gold). Strokes follow only the top curve —
//  there are no side bands, since the strokes' endpoints extend off-
//  screen and get clipped by the view bounds.
//
//  Why strokes instead of nested filled shapes (the old "matryoshka"):
//    - Filled nested arches inevitably show vertical bands on the left
//      and right edges (the inner shape's vertical sides are inset from
//      the outer's, leaving the outer's color visible as a strip).
//    - With open stroked curves, the visible band exists ONLY along the
//      curve's top arc; below it the play area shows through cleanly.
//    - Endpoints extend `extendOffscreen` past the visible bounds so the
//      stroke caps don't show as bevels at the screen edges.
//

import UIKit

@available(iOS 26, *)
final class FeudArchBackground: UIView {

    // MARK: - Layout constants

    /// How many points the arch curve descends from peak to base. With
    /// the arch now anchored to safe-area top (below the nav bar), 60pt
    /// gives a more pronounced sweep that's still tight enough for the
    /// banner to sit just below the curve at its sides.
    private static let archDepth: CGFloat = 60

    /// Outer (dark brown) stroke thickness.
    private static let outerLineWidth: CGFloat = 14

    /// Inner (gold) stroke thickness.
    private static let innerLineWidth: CGFloat = 8

    /// Distance the inner stroke is offset DOWN from the outer stroke,
    /// in points. Larger value = more visible gap; smaller = bands hug.
    /// We use about half of (outer + inner)/2 so they touch with a 1pt
    /// crossover, yielding a clean side-by-side band effect.
    private static let bandSeparation: CGFloat = (outerLineWidth + innerLineWidth) / 2 - 2

    /// Path endpoints extend this many points past the visible bounds.
    /// Hides the stroke's cap (which would otherwise show a bevel at the
    /// screen edges).
    private static let extendOffscreen: CGFloat = 40

    // MARK: - Layers

    private let outerStrokeLayer = CAShapeLayer()
    private let innerStrokeLayer = CAShapeLayer()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(patternImage: Self.makeDotTile())

        outerStrokeLayer.fillColor = UIColor.clear.cgColor
        outerStrokeLayer.strokeColor = FeudPalette.frameDarkBrown.cgColor
        outerStrokeLayer.lineWidth = Self.outerLineWidth
        outerStrokeLayer.lineCap = .butt
        layer.addSublayer(outerStrokeLayer)

        innerStrokeLayer.fillColor = UIColor.clear.cgColor
        innerStrokeLayer.strokeColor = FeudPalette.goldBorder.cgColor
        innerStrokeLayer.lineWidth = Self.innerLineWidth
        innerStrokeLayer.lineCap = .butt
        layer.addSublayer(innerStrokeLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let archDepth = Self.archDepth
        let separation = Self.bandSeparation

        outerStrokeLayer.frame = bounds
        innerStrokeLayer.frame = bounds

        // Outer stroke at the top-most arch position.
        outerStrokeLayer.path = Self.makeTopCurve(
            in: bounds, archDepth: archDepth
        ).cgPath

        // Inner stroke offset DOWN by `separation` so it appears as a
        // distinct gold band under the dark brown one.
        innerStrokeLayer.path = Self.makeTopCurve(
            in: bounds, archDepth: archDepth + separation
        ).cgPath
    }

    // MARK: - Geometry

    /// Open quadratic-Bézier "top curve" of the arch. Endpoints extend
    /// `extendOffscreen` to either side of the visible bounds, so the
    /// stroke's start/end caps fall outside the rendered viewport.
    ///
    /// The curve construction uses the same algebraic trick as the old
    /// closed arch path: control point at `(W/2, -archDepth)` puts the
    /// apex exactly at `(W/2, 0)`, and `y(t) = archDepth · (1-2t)²` is
    /// always ≥ 0, so the path stays in non-negative y.
    private static func makeTopCurve(in rect: CGRect, archDepth: CGFloat) -> UIBezierPath {
        let extend = extendOffscreen
        let extendedW = rect.width + 2 * extend

        let path = UIBezierPath()
        // Build in extended-local coords (origin at extended-rect's left)
        path.move(to: CGPoint(x: 0, y: archDepth))
        path.addQuadCurve(
            to: CGPoint(x: extendedW, y: archDepth),
            controlPoint: CGPoint(x: extendedW / 2, y: -archDepth)
        )
        // Shift so the visible center stays centered in `rect`
        path.apply(CGAffineTransform(translationX: -extend, y: 0))
        return path
    }

    // MARK: - Dot pattern

    private static func makeDotTile() -> UIImage {
        // Tile size kept at 22 for density; dot bumped to 9pt so each
        // bulb reads as a distinct round disc rather than a pinprick.
        let tileSize = CGSize(width: 22, height: 22)
        let dotDiameter: CGFloat = 9
        let renderer = UIGraphicsImageRenderer(size: tileSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(FeudPalette.archBackground.cgColor)  // pure black
            cg.fill(CGRect(origin: .zero, size: tileSize))
            cg.setFillColor(FeudPalette.goldBorder.withAlphaComponent(0.7).cgColor)
            let dotRect = CGRect(
                x: (tileSize.width - dotDiameter) / 2,
                y: (tileSize.height - dotDiameter) / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            cg.fillEllipse(in: dotRect)
        }
    }
}
