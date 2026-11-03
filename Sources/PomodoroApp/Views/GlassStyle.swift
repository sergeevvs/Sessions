import AppKit
import SwiftUI

enum PomodoroStyle {
    static let panelWidth: CGFloat = 288
    static let panelHeight: CGFloat = 480
    static let accent = adaptive(light: 0x078779, dark: 0x52C2B0)
    static let accentHighlight = adaptive(light: 0x45A79B, dark: 0x298F83)
    static let buttonAccent = Color(red: 7 / 255, green: 135 / 255, blue: 121 / 255)
    static let ink = adaptive(light: 0x263B40, dark: 0xEDF6F8)
    static let secondary = adaptive(light: 0x5C6E73, dark: 0xB2C4CC)
    static let base = adaptive(light: 0xE8EEF0, dark: 0x24323D)
    static let track = adaptive(light: 0x344E56, dark: 0xE3FAFF).opacity(0.11)
    static let line = adaptive(light: 0x3A535E, dark: 0xE1F6FF).opacity(0.09)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct GlassPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The native popover clips the full-size background to its own outline,
        // including corners and arrow. A second rounded panel leaves unfilled gaps.
        let shape = Rectangle()
        ZStack {
            if reduceTransparency {
                shape.fill(PomodoroStyle.base)
            } else {
                shape.fill(.clear).glassEffect(.regular, in: shape)
                shape.fill(PomodoroStyle.base.opacity(0.86))
                shape.fill(RadialGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.70), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 310))
                shape.fill(RadialGradient(
                    colors: [PomodoroStyle.accent.opacity(colorScheme == .dark ? 0.13 : 0.12), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 320))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A native button whose label and surface share the reference's actual bounds.
/// System button styles can choose smaller AppKit bezels inside a larger frame.
struct PomodoroButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 34
    var radius: CGFloat = 11
    var emphasized = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, emphasized ? 6 : 8)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(prominent ? Color.white : PomodoroStyle.ink)
            .background {
                GlassControlSurface(prominent: prominent, radius: radius, emphasized: emphasized)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(PomodoroStyle.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct GlassControlSurface: View {
    let prominent: Bool
    let radius: CGFloat
    let emphasized: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var fillOpacity: (top: Double, bottom: Double) {
        if colorScheme == .dark {
            return emphasized ? (0.16, 0.10) : (0.08, 0.03)
        }
        return emphasized ? (0.95, 0.82) : (0.54, 0.30)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        ZStack {
            if reduceTransparency {
                shape.fill(prominent ? PomodoroStyle.buttonAccent : Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.clear)
                    .glassEffect(emphasized ? .regular : .clear, in: shape)
                if prominent {
                    if contrast == .increased {
                        shape.fill(Color(red: 0, green: 0.38, blue: 0.34))
                    } else {
                        shape.fill(LinearGradient(
                            colors: [PomodoroStyle.accentHighlight, PomodoroStyle.buttonAccent],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                } else {
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(fillOpacity.top), .white.opacity(fillOpacity.bottom)],
                        startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .overlay {
            if contrast == .increased && !prominent {
                shape.strokeBorder(PomodoroStyle.secondary.opacity(emphasized ? 0.85 : 0.6), lineWidth: 1)
            } else if emphasized {
                shape.strokeBorder(PomodoroStyle.ink.opacity(colorScheme == .dark ? 0.45 : 0.32), lineWidth: 1)
            } else {
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.25 : 0.84),
                             .white.opacity(colorScheme == .dark ? 0.12 : 0.58)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
        .shadow(color: (prominent ? PomodoroStyle.accent : .black)
            .opacity(prominent ? 0.16 : emphasized ? 0.14 : 0.035),
                radius: prominent ? 4 : emphasized ? 3 : 1, y: prominent ? 2 : 1)
        .allowsHitTesting(false)
    }
}

struct GlassActionButton: View {
    let title: String
    let systemImage: String
    var prominent: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: prominent ? 14 : 13, weight: .regular))
                    .accessibilityHidden(true)
                Text(title)
            }
            .font(.system(size: prominent ? 13 : 12, weight: .medium))
        }
        .buttonStyle(PomodoroButtonStyle(prominent: prominent,
                                        height: prominent ? 41 : 34,
                                        radius: prominent ? 13 : 11))
    }
}

struct GlassSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? PomodoroStyle.accent : PomodoroStyle.track)
                    Capsule().strokeBorder(PomodoroStyle.secondary.opacity(contrast == .increased ? 0.65 : 0.13), lineWidth: 1)
                    Circle()
                        .fill(LinearGradient(colors: [.white, Color(white: 0.96)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .padding(2)
                }
                .frame(width: 29, height: 18)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PomodoroStyle.ink)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
