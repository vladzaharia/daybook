#if DEBUG
import PencilKit

/// Single-stroke letters, smoothed, in the shape a pen draws them: enough to exercise the recognizer without a Pencil.
enum SyntheticInk {
    private static let glyphs: [Character: [[CGPoint]]] = [
        "h": [[.init(x: 0.1, y: 0), .init(x: 0.1, y: 1)],
              [.init(x: 0.1, y: 0.55), .init(x: 0.3, y: 0.42), .init(x: 0.6, y: 0.42), .init(x: 0.75, y: 0.55), .init(x: 0.75, y: 1)]],
        "e": [[.init(x: 0.1, y: 0.7), .init(x: 0.8, y: 0.7), .init(x: 0.78, y: 0.5), .init(x: 0.5, y: 0.4), .init(x: 0.2, y: 0.5),
               .init(x: 0.08, y: 0.72), .init(x: 0.2, y: 0.95), .init(x: 0.5, y: 1.02), .init(x: 0.8, y: 0.92)]],
        "l": [[.init(x: 0.3, y: 0), .init(x: 0.3, y: 1)]],
        "o": [[.init(x: 0.45, y: 0.42), .init(x: 0.15, y: 0.55), .init(x: 0.1, y: 0.75), .init(x: 0.25, y: 0.97), .init(x: 0.55, y: 1.02),
               .init(x: 0.8, y: 0.85), .init(x: 0.82, y: 0.6), .init(x: 0.65, y: 0.45), .init(x: 0.45, y: 0.42)]],
        "w": [[.init(x: 0.05, y: 0.42), .init(x: 0.25, y: 1), .init(x: 0.45, y: 0.55), .init(x: 0.65, y: 1), .init(x: 0.9, y: 0.42)]],
        "r": [[.init(x: 0.15, y: 0.42), .init(x: 0.15, y: 1)], [.init(x: 0.15, y: 0.6), .init(x: 0.35, y: 0.45), .init(x: 0.6, y: 0.42)]],
        "d": [[.init(x: 0.7, y: 0.55), .init(x: 0.45, y: 0.42), .init(x: 0.15, y: 0.55), .init(x: 0.1, y: 0.75), .init(x: 0.25, y: 0.97),
               .init(x: 0.55, y: 1.0), .init(x: 0.7, y: 0.85)],
              [.init(x: 0.72, y: 0), .init(x: 0.72, y: 1)]],
    ]

    static func drawing(_ text: String, size: CGFloat = 46, origin: CGPoint = CGPoint(x: 20, y: 20)) -> PKDrawing {
        var strokes: [PKStroke] = []
        let ink = PKInk(.pen, color: .black)
        var x = origin.x
        var clock: TimeInterval = 0
        for character in text {
            if character == " " { x += size * 0.55; continue }
            for stroke in glyphs[character] ?? [] {
                let points: [PKStrokePoint] = smoothed(stroke).map { point in
                    let location = CGPoint(x: x + point.x * size * 0.8, y: origin.y + point.y * size)
                    clock += 0.012
                    return PKStrokePoint(location: location, timeOffset: clock, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
            x += size * 0.82
        }
        return PKDrawing(strokes: strokes)
    }

    private static func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else {
            return stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                CGPoint(x: points[0].x + (points[1].x - points[0].x) * t, y: points[0].y + (points[1].y - points[0].y) * t)
            }
        }
        var output: [CGPoint] = []
        for index in 0..<(points.count - 1) {
            let a = points[max(index - 1, 0)], b = points[index], c = points[index + 1], d = points[min(index + 2, points.count - 1)]
            for t in stride(from: 0.0, to: 1.0, by: 0.08) {
                let t2 = t * t, t3 = t2 * t
                func curve(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
                    0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
                }
                output.append(CGPoint(x: curve(a.x, b.x, c.x, d.x), y: curve(a.y, b.y, c.y, d.y)))
            }
        }
        output.append(points[points.count - 1])
        return output
    }
}
#endif
