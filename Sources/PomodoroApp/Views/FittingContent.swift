import SwiftUI

/// Normal panels show every control. Only constrained screens or exceptional
/// diagnostic text need scrolling, with no indicators over the glass surface.
struct FittingContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView(.vertical, showsIndicators: false) {
                content()
            }
            .defaultScrollAnchor(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
