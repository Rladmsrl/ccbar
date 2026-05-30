import SwiftUI

extension Animation {
    static let stxNumericValueChange: Animation = .easeOut(duration: 0.18)
}

extension View {
    func stxNumericValueTransition<Value: Equatable>(value: Value) -> some View {
        contentTransition(.numericText())
            .animation(.stxNumericValueChange, value: value)
    }
}

struct NumericValueTransitionIfEnabled<Value: Equatable>: ViewModifier {
    var enabled: Bool
    var value: Value

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.stxNumericValueTransition(value: value)
        } else {
            content
        }
    }
}
