import SwiftUI

enum FlowStyle {
    static let accent = Color.accentColor
    static let border = Color.primary.opacity(0.09)
    static let secondaryBackground = Color(nsColor: .controlBackgroundColor)
}

struct FlowCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(FlowStyle.border))
    }
}

extension View {
    func flowCard() -> some View { modifier(FlowCard()) }
}
