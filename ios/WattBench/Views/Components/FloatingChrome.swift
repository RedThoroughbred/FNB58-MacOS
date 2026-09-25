import SwiftUI

/// Material backing for floating chrome (status pill, record bar, chart
/// readout, alert banner). Adopts the system glass effect when built with the
/// iOS 26+ SDK and running on iOS 26+, so custom chrome matches the system.
struct FloatingChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

extension View {
    func floatingChrome(_ shape: some InsettableShape) -> some View {
        modifier(FloatingChrome(shape: shape))
    }
}
