import SwiftUI

/// Material backing for floating chrome (status pill, record bar, chart
/// readout, alert banner). Adopts the system glass effect when built with the
/// iOS 26+ SDK and running on iOS 26+, so custom chrome matches the system's
/// Liquid Glass; earlier systems get the given material in the same shape.
struct FloatingChrome<S: InsettableShape>: ViewModifier {
    let shape: S
    var material: Material = .thinMaterial

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

extension View {
    /// Thin material (or glass on iOS 26+) in `shape`.
    func floatingChrome(_ shape: some InsettableShape) -> some View {
        modifier(FloatingChrome(shape: shape))
    }

    /// A specific material (`.bar` for the record bar, `.regularMaterial`
    /// for the chart readout) in `shape`; glass on iOS 26+.
    func floatingChrome(_ shape: some InsettableShape, material: Material) -> some View {
        modifier(FloatingChrome(shape: shape, material: material))
    }
}
