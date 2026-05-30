import SwiftUI

/// Repeating 45° lines from top-right to bottom-left. Used to overlay the
/// cache-hit portion of a model-coloured bar so it reads as "same colour,
/// different fill". The stroke colour is supplied by the caller (typically a
/// light translucent white that blends with the warm model colour).
struct DiagonalStripes: Shape {
    var spacing: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = rect.height
        // Start past the left edge so the leftmost diagonals are drawn fully.
        var x = -h
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: h))
            p.addLine(to: CGPoint(x: x + h, y: 0))
            x += spacing
        }
        return p
    }
}
