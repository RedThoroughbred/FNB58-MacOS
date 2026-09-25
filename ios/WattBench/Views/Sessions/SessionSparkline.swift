import SwiftUI

/// Mean-power trace drawn with `Canvas` from `SessionSummary.sparkline`
/// (at most 60 values). Never a `Chart`: a List of sessions holds dozens of
/// these and must scroll without allocating a chart renderer per row.
struct SessionSparkline: View {
    let values: [Float]
    var color: Color = .power
    var lineWidth: CGFloat = 1.5
    /// Adds the metric-colour gradient fill used by the larger preview card.
    var fill = false

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2, size.width > 0, size.height > 0 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 0
            let span = hi - lo
            let inset = lineWidth
            let drawable = max(size.height - 2 * inset, 1)
            let stepX = size.width / CGFloat(values.count - 1)

            func point(_ i: Int) -> CGPoint {
                let v = values[i]
                // Flat traces sit on the midline instead of the floor.
                let unit = span > 0 ? CGFloat((v - lo) / span) : 0.5
                return CGPoint(x: CGFloat(i) * stepX, y: size.height - inset - unit * drawable)
            }

            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }

            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.25), color.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
