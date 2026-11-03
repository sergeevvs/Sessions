import Observation
import SwiftUI

/// The controller resolves both native and SwiftUI colors from one appearance.
@MainActor
@Observable
final class PopoverAppearance {
    var colorScheme: ColorScheme = .light
}
