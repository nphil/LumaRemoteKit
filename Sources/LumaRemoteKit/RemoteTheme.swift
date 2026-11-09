#if canImport(SwiftUI)
import SwiftUI

/// The remote's look, supplied by the host app: colours by role, radii and typefaces. Every view in the
/// kit draws from it, so a host theme change restyles the remote live. The default follows the system.
public struct RemoteTheme: Sendable {
    public struct Palette: Sendable {
        /// The screen behind everything.
        public var canvas: Color
        /// Large calm surfaces: the D-pad, the touchpad, the rockers.
        public var surface: Color
        /// Buttons on a surface.
        public var surfaceRaised: Color
        /// Hairlines around surfaces and buttons.
        public var edge: Color
        public var ink: Color
        public var ink2: Color
        public var ink3: Color
        public var accent: Color
        /// Text and glyphs on `accent`.
        public var accentInk: Color
        /// The pressed-state wash.
        public var focus: Color
        public var positive: Color
        public var warning: Color
        public var danger: Color
        public var info: Color

        public init(
            canvas: Color, surface: Color, surfaceRaised: Color, edge: Color,
            ink: Color, ink2: Color, ink3: Color, accent: Color, accentInk: Color, focus: Color,
            positive: Color, warning: Color, danger: Color, info: Color
        ) {
            self.canvas = canvas
            self.surface = surface
            self.surfaceRaised = surfaceRaised
            self.edge = edge
            self.ink = ink
            self.ink2 = ink2
            self.ink3 = ink3
            self.accent = accent
            self.accentInk = accentInk
            self.focus = focus
            self.positive = positive
            self.warning = warning
            self.danger = danger
            self.info = info
        }

        /// System colours with the given tint.
        public static func system(tint: Color = .accentColor) -> Palette {
            #if os(iOS)
            Palette(
                canvas: Color(uiColor: .systemBackground), surface: Color(uiColor: .secondarySystemBackground),
                surfaceRaised: Color(uiColor: .tertiarySystemBackground), edge: Color(uiColor: .separator),
                ink: .primary, ink2: .secondary, ink3: Color(uiColor: .tertiaryLabel), accent: tint, accentInk: .white,
                focus: tint.opacity(0.22), positive: .green, warning: .orange, danger: .red, info: .blue
            )
            #else
            Palette(
                canvas: Color(nsColor: .windowBackgroundColor), surface: Color(nsColor: .controlBackgroundColor),
                surfaceRaised: Color(nsColor: .underPageBackgroundColor), edge: Color(nsColor: .separatorColor),
                ink: .primary, ink2: .secondary, ink3: Color(nsColor: .tertiaryLabelColor), accent: tint, accentInk: .white,
                focus: tint.opacity(0.22), positive: .green, warning: .orange, danger: .red, info: .blue
            )
            #endif
        }
    }

    public struct Radii: Sendable {
        /// The D-pad's plate, the touchpad, the More sheet's groups.
        public var surface: CGFloat
        /// Capsule-less buttons and fields.
        public var control: CGFloat

        public init(surface: CGFloat = 24, control: CGFloat = 14) {
            self.surface = surface
            self.control = control
        }
    }

    /// PostScript names of the host's typeface cuts; nil uses the system font.
    public struct Typefaces: Sendable {
        public var regular: String?
        public var medium: String?
        public var semibold: String?
        public var bold: String?
        /// Whether the cuts set only titles (`.largeTitle` to `.title3`) and the rest stays in the system font.
        public var titlesOnly: Bool

        public init(regular: String? = nil, medium: String? = nil, semibold: String? = nil, bold: String? = nil, titlesOnly: Bool = false) {
            self.regular = regular
            self.medium = medium
            self.semibold = semibold
            self.bold = bold
            self.titlesOnly = titlesOnly
        }
    }

    public var palette: Palette
    /// The light or dark appearance the palette is made for; nil follows the system.
    public var colorScheme: ColorScheme?
    public var radii: Radii
    public var typefaces: Typefaces

    public init(palette: Palette = .system(), colorScheme: ColorScheme? = nil, radii: Radii = Radii(), typefaces: Typefaces = Typefaces()) {
        self.palette = palette
        self.colorScheme = colorScheme
        self.radii = radii
        self.typefaces = typefaces
    }

    public static let system = RemoteTheme()

    /// The host's typeface at a text style's size, scaling with Dynamic Type.
    public func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let isTitle = ([.largeTitle, .title, .title2, .title3] as [Font.TextStyle]).contains(style)
        let name: String? = switch weight {
        case _ where typefaces.titlesOnly && !isTitle: nil
        case .bold, .heavy, .black: typefaces.bold
        case .semibold: typefaces.semibold
        case .medium: typefaces.medium
        default: typefaces.regular
        }
        guard let name else { return .system(style, weight: weight) }
        return .custom(name, size: Self.baseSize(style), relativeTo: style)
    }

    /// The default sizes at the Large content size.
    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

private struct RemoteThemeKey: EnvironmentKey {
    static let defaultValue = RemoteTheme.system
}

extension EnvironmentValues {
    public var lumaRemoteTheme: RemoteTheme {
        get { self[RemoteThemeKey.self] }
        set { self[RemoteThemeKey.self] = newValue }
    }
}

extension View {
    /// Styles every remote view inside with the host's theme.
    public func lumaRemoteTheme(_ theme: RemoteTheme) -> some View {
        environment(\.lumaRemoteTheme, theme)
    }
}
#endif
