import SwiftUI

enum TsumibenTheme {
    static let background = Color("ink.night")
    static let card = Color("ink.card")
    static let raised = Color("ink.raised")
    static let glassEdge = Color("glass.edge")
    static let amber = Color("amber.lamp")
    static let text = Color("text.warm")
    static let muted = Color("text.mute")
    static let bedrock = Color("rock.bed")
    static let auroraWarm = Color(hex: Constants.Color.auroraWarm)
    static let auroraBlue = Color(hex: Constants.Color.auroraCool)
    static let auroraViolet = Color(hex: Constants.Color.auroraViolet)
    static let specular = Color(hex: Constants.Color.auroraCool)

    static func brand(_ size: CGFloat) -> Font {
        .custom("ZenMaruGothic-Black", size: size, relativeTo: .title)
    }

    static func rounded(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

/// A deliberately small set of home atmospheres. The subject color remains
/// the semantic accent; these presets only change the surrounding space, so a
/// user never has to relearn what their category color means.
enum HomeAtmosphere: String, CaseIterable, Identifiable {
    static let storageKey = "home.atmosphere"

    case midnight
    case aurora
    case dawn
    case study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: "深夜"
        case .aurora: "オーロラ"
        case .dawn: "朝凪"
        case .study: "書斎"
        }
    }

    var subtitle: String {
        switch self {
        case .midnight: "静かな定番"
        case .aurora: "光に包まれる"
        case .dawn: "昼にも軽やか"
        case .study: "仕事にも馴染む"
        }
    }

    var systemImage: String {
        switch self {
        case .midnight: "moon.stars.fill"
        case .aurora: "sparkles"
        case .dawn: "sun.horizon.fill"
        case .study: "lamp.desk.fill"
        }
    }

    var paletteHexes: [String] {
        switch self {
        case .midnight: ["081225", "2454A6", "8157D8"]
        case .aurora: ["071021", "614EEA", "FF7969"]
        case .dawn: ["26354A", "C77970", "FFD089"]
        case .study: ["101719", "285D5B", "CDAA68"]
        }
    }

    /// Environmental light belongs to the selected atmosphere, never to the
    /// active subject. Subject color is reserved for gems and the primary CTA.
    var ambientAccent: Color {
        switch self {
        case .midnight: TsumibenTheme.auroraBlue
        case .aurora: TsumibenTheme.auroraViolet
        case .dawn: TsumibenTheme.auroraWarm
        case .study: Color(hex: Constants.Color.amberLamp)
        }
    }

    static func resolved(_ rawValue: String) -> HomeAtmosphere {
        HomeAtmosphere(rawValue: rawValue) ?? .midnight
    }
}

/// The branded content layer on Home. Interactive controls stay in the native
/// material layer above it; the background itself is intentionally static to
/// keep SpriteKit as the only continuous renderer on the screen.
struct HomeAtmosphereBackground: View {
    let atmosphere: HomeAtmosphere
    var accent: Color = TsumibenTheme.auroraBlue

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            TsumibenTheme.background

            atmosphereArtwork

            LinearGradient(
                colors: [
                    Color.black.opacity(0.02),
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.48)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    accent.opacity(reduceTransparency ? 0.04 : 0.10),
                    .clear
                ],
                center: UnitPoint(x: 0.52, y: 0.48),
                startRadius: 18,
                endRadius: 430
            )

            if !reduceTransparency {
                NightLightDust()
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var atmosphereArtwork: some View {
        switch atmosphere {
        case .midnight:
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.08, blue: 0.16),
                    Color(red: 0.07, green: 0.11, blue: 0.24),
                    TsumibenTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [TsumibenTheme.auroraViolet.opacity(0.16), .clear],
                center: UnitPoint(x: 0.03, y: 0.44),
                startRadius: 12,
                endRadius: 430
            )

        case .aurora:
            Image("focus.aurora")
                .resizable()
                .scaledToFill()
                // This is static artwork rather than translucent interface
                // chrome, so preserve its color identity when Reduce
                // Transparency is enabled. Contrast comes from the dark veil.
                .opacity(reduceTransparency ? 0.64 : 0.78)
            Color.black.opacity(reduceTransparency ? 0.34 : 0.24)

        case .dawn:
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.21, blue: 0.29),
                    Color(red: 0.42, green: 0.25, blue: 0.25),
                    Color(red: 0.06, green: 0.08, blue: 0.12)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 1.0, green: 0.76, blue: 0.50).opacity(0.34), .clear],
                center: UnitPoint(x: 0.82, y: 0.04),
                startRadius: 6,
                endRadius: 360
            )

        case .study:
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.09, blue: 0.10),
                    Color(red: 0.06, green: 0.15, blue: 0.15),
                    Color(red: 0.03, green: 0.06, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.79, green: 0.65, blue: 0.39).opacity(0.15), .clear],
                center: UnitPoint(x: 0.15, y: 0.14),
                startRadius: 8,
                endRadius: 330
            )
        }
    }
}

struct NightBackground: View {
    var accent: Color = TsumibenTheme.auroraBlue
    var immersive = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            TsumibenTheme.background

            LinearGradient(
                colors: [
                    Color.black.opacity(0.10),
                    TsumibenTheme.background.opacity(0.16),
                    Color.black.opacity(0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    accent.opacity(reduceTransparency ? 0.06 : (immersive ? 0.20 : 0.09)),
                    .clear
                ],
                center: UnitPoint(x: 0.82, y: 0.12),
                startRadius: 8,
                endRadius: immersive ? 520 : 440
            )

            if immersive, !reduceTransparency {
                RadialGradient(
                    colors: [TsumibenTheme.auroraViolet.opacity(0.13), .clear],
                    center: UnitPoint(x: 0.08, y: 0.58),
                    startRadius: 16,
                    endRadius: 420
                )

                NightLightDust()
            }
        }
        .ignoresSafeArea()
    }
}

/// A tiny, deterministic field of low-contrast light points. It is rendered
/// once by Canvas (rather than animated) so SpriteKit remains the only live
/// 60-fps surface on Home.
private struct NightLightDust: View {
    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            for index in 0..<22 {
                let xUnit = Self.unit(index * 37 + 11)
                let yUnit = Self.unit(index * 61 + 23)
                let diameter = index.isMultiple(of: 5) ? 2.4 : 1.35
                let rect = CGRect(
                    x: xUnit * size.width,
                    y: yUnit * size.height * 0.78,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(TsumibenTheme.specular.opacity(index.isMultiple(of: 5) ? 0.20 : 0.10))
                )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func unit(_ value: Int) -> CGFloat {
        CGFloat((value * 73) % 997) / 997
    }
}

struct TsumibenCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(TsumibenTheme.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(TsumibenTheme.glassEdge.opacity(0.12), lineWidth: 1)
                    }
            )
    }
}

struct TsumibenPrimaryButtonStyle: ButtonStyle {
    var tint: Color = TsumibenTheme.amber
    var foreground: Color = TsumibenTheme.background

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    init(
        tint: Color = TsumibenTheme.amber,
        foreground: Color = TsumibenTheme.background
    ) {
        self.tint = tint
        self.foreground = foreground
    }

    init(tintHex: String) {
        tint = Color(hex: tintHex)
        foreground = TsumibenTheme.readableForeground(onHex: tintHex)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                foreground.opacity(configuration.isPressed ? 0.34 : 0.14),
                                lineWidth: configuration.isPressed ? 2 : 1
                            )
                    }
                    .shadow(
                        color: tint.opacity(isEnabled && !configuration.isPressed ? 0.22 : 0.06),
                        radius: configuration.isPressed ? 8 : 18,
                        y: configuration.isPressed ? 3 : 8
                    )
            )
            .saturation(isEnabled ? 1 : 0.18)
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

struct TsumibenSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(TsumibenTheme.text)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TsumibenTheme.raised.opacity(configuration.isPressed ? 0.72 : 1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                TsumibenTheme.glassEdge.opacity(configuration.isPressed ? 0.34 : 0.14),
                                lineWidth: configuration.isPressed ? 1.5 : 1
                            )
                    }
            )
            .saturation(isEnabled ? 1 : 0.12)
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

/// For controls whose label already draws its complete shape (chips, circular
/// nodes, bottle cards). It adds only common press and disabled feedback.
struct TsumibenBareButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .saturation(isEnabled ? 1 : 0.16)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.43)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.975 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.10), value: isEnabled)
    }
}

/// Press feedback for tappable rows and choice cards that own their own visual
/// surface. This keeps `.plain` semantics without leaving dozens of controls
/// with no common pressed or disabled state.
struct TsumibenRowButtonStyle: ButtonStyle {
    var isSelected = false
    var cornerRadius: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? TsumibenTheme.amber.opacity(0.10)
                            : Color.white.opacity(configuration.isPressed ? 0.055 : 0)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isSelected
                            ? TsumibenTheme.amber.opacity(0.50)
                            : TsumibenTheme.glassEdge.opacity(configuration.isPressed ? 0.28 : 0),
                        lineWidth: isSelected ? 1 : 0.75
                    )
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.992 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Compact icon actions use the same 44pt circular target everywhere. Native
/// toggles, pickers and alert roles remain native controls.
struct TsumibenIconButtonStyle: ButtonStyle {
    var tint: Color = TsumibenTheme.text

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(
                Circle()
                    .fill(TsumibenTheme.raised.opacity(configuration.isPressed ? 0.70 : 0.92))
                    .overlay {
                        Circle().stroke(TsumibenTheme.glassEdge.opacity(0.18), lineWidth: 1)
                    }
            )
            .opacity(isEnabled ? 1 : 0.44)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// A 44pt capsule for compact contextual actions such as retry, rest and GIF.
/// Use the full-width primary/secondary styles for the main screen CTA.
struct TsumibenCompactButtonStyle: ButtonStyle {
    var tint: Color = TsumibenTheme.amber
    var foreground: Color = TsumibenTheme.background
    var isProminent = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(isProminent ? foreground : tint)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(
                Capsule()
                    .fill(
                        isProminent
                            ? tint
                            : TsumibenTheme.raised.opacity(configuration.isPressed ? 0.72 : 0.94)
                    )
                    .overlay {
                        Capsule().stroke(
                            (isProminent ? foreground : tint).opacity(configuration.isPressed ? 0.38 : 0.20),
                            lineWidth: configuration.isPressed ? 1.5 : 1
                        )
                    }
            )
            .saturation(isEnabled ? 1 : 0.16)
            .opacity(isEnabled ? 1 : 0.44)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.96 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Every full-screen sheet uses this compact exit control. Work cancellation
/// remains a separate action so “閉じる” never changes meaning while loading.
private struct TsumibenSheetCloseButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(TsumibenTheme.background)
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TsumibenTheme.amber)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                TsumibenTheme.background.opacity(
                                    configuration.isPressed ? 0.38 : 0.20
                                ),
                                lineWidth: configuration.isPressed ? 1.5 : 1
                            )
                    }
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .saturation(isEnabled ? 1 : 0.16)
            .opacity(isEnabled ? 1 : 0.44)
            .scaleEffect(
                reduceMotion || !isEnabled
                    ? 1
                    : (configuration.isPressed ? 0.96 : 1)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
}

struct TsumibenSheetCloseButton: View {
    var accessibilityLabel = "閉じる"
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        styledButton
            .frame(minWidth: 68, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    @ViewBuilder
    private var styledButton: some View {
        if #available(iOS 26.0, *) {
            // Toolbars supply their own Liquid Glass surface on iOS 26.
            // A custom filled background here would render as a second shape.
            closeButton
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .tint(TsumibenTheme.amber)
        } else {
            closeButton
                .buttonStyle(TsumibenSheetCloseButtonStyle())
        }
    }

    private var closeButton: some View {
        Button(action: action) {
            Text("閉じる")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(TsumibenTheme.background)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}

struct TsumibenDestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .bold))
            .foregroundStyle(Color.red.opacity(0.94))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.14 : 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.red.opacity(configuration.isPressed ? 0.48 : 0.24), lineWidth: 1)
                    }
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// The single high-emphasis control on Home. Its layered highlight and
/// occlusion shadows suggest a physical control without requiring 3D assets.
struct TsumibenHeroButtonStyle: ButtonStyle {
    var tint: Color
    var foreground: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    init(tintHex: String) {
        tint = Color(hex: tintHex)
        foreground = TsumibenTheme.readableForeground(onHex: tintHex)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .padding(.horizontal, 18)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint,
                                    tint.opacity(0.82)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    if !reduceTransparency {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.22), .clear, .black.opacity(0.13)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            }
            .shadow(
                color: tint.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.30) : 0.04),
                radius: configuration.isPressed ? 12 : 28,
                y: configuration.isPressed ? 5 : 14
            )
            .shadow(color: .black.opacity(0.30), radius: 8, y: 5)
            .saturation(isEnabled ? 1 : 0.16)
            .opacity(isEnabled ? 1 : 0.47)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : (configuration.isPressed ? 0.975 : 1))
            .offset(y: reduceMotion || !isEnabled ? 0 : (configuration.isPressed ? 2 : 0))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

struct SectionEyebrow: View {
    let text: String
    var foreground: Color = TsumibenTheme.amber
    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 10

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(foreground)
            .accessibilityHidden(true)
    }
}

extension TsumibenTheme {
    /// Chooses the higher-contrast monochrome foreground for an sRGB hex background.
    /// Invalid values fall back to the normal warm text instead of guessing a color.
    static func readableForeground(onHex hex: String) -> Color {
        guard let luminance = relativeLuminance(ofHex: hex) else { return text }
        let darkContrast = (luminance + 0.05) / 0.05
        let lightContrast = 1.05 / (luminance + 0.05)
        return darkContrast >= lightContrast ? .black : .white
    }

    private static func relativeLuminance(ofHex hex: String) -> Double? {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else { return nil }
        let red = linearizedSRGB(Double((value >> 16) & 0xFF) / 255.0)
        let green = linearizedSRGB(Double((value >> 8) & 0xFF) / 255.0)
        let blue = linearizedSRGB(Double(value & 0xFF) / 255.0)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func linearizedSRGB(_ component: Double) -> Double {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}

extension View {
    func tsumibenNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbarBackground(TsumibenTheme.background.opacity(0.92), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
