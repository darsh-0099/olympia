import SwiftUI
import Combine

enum SolarBackgroundPreset: String, CaseIterable, Codable, Identifiable {
    case solar = "Solar Default"
    case midnight = "Midnight Blue"
    case graphite = "Graphite"
    var id: String { rawValue }
}

enum SolarAccentPreset: String, CaseIterable, Codable, Identifiable {
    case solar = "Solar Orange"
    case aurora = "Aurora Cyan"
    case violet = "Orbit Violet"
    var id: String { rawValue }
}

enum SolarAppearancePreference: String, CaseIterable, Codable, Identifiable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"
    var id: String { rawValue }
}

struct SolarThemePreferences: Codable, Equatable {
    var background: SolarBackgroundPreset = .solar
    var accent: SolarAccentPreset = .aurora
    var appearance: SolarAppearancePreference = .system
    var highContrast = false
    var reducedAnimation = false
    static let solarDefault = SolarThemePreferences()
}

struct SolarThemePalette {
    let background: Color
    let surface: Color
    let elevated: Color
    let accent: Color
    let secondaryAccent: Color
    let primaryText: Color
    let secondaryText: Color
    let highContrast: Bool
    let reducedAnimation: Bool

    init(_ preferences: SolarThemePreferences = .solarDefault) {
        switch preferences.background {
        case .solar:
            background = SolarColor.background; surface = SolarColor.surface; elevated = SolarColor.elevated
        case .midnight:
            background = Color(red: 0.025, green: 0.065, blue: 0.12)
            surface = Color(red: 0.06, green: 0.12, blue: 0.19)
            elevated = Color(red: 0.09, green: 0.17, blue: 0.25)
        case .graphite:
            background = Color(red: 0.075, green: 0.075, blue: 0.08)
            surface = Color(red: 0.13, green: 0.13, blue: 0.14)
            elevated = Color(red: 0.18, green: 0.18, blue: 0.20)
        }
        switch preferences.accent {
        case .solar: accent = SolarColor.sun; secondaryAccent = SolarColor.gold
        case .aurora: accent = Color(red: 0.39, green: 0.78, blue: 1.0); secondaryAccent = Color(red: 0.55, green: 0.86, blue: 1.0)
        case .violet: accent = Color(red: 0.68, green: 0.48, blue: 1); secondaryAccent = Color(red: 0.94, green: 0.55, blue: 0.94)
        }
        primaryText = preferences.highContrast ? .white : SolarColor.textPrimary
        secondaryText = preferences.highContrast ? .white.opacity(0.82) : SolarColor.textSecondary
        highContrast = preferences.highContrast
        reducedAnimation = preferences.reducedAnimation
    }
}

private struct SolarThemeKey: EnvironmentKey {
    static let defaultValue = SolarThemePalette()
}

extension EnvironmentValues {
    var solarTheme: SolarThemePalette {
        get { self[SolarThemeKey.self] }
        set { self[SolarThemeKey.self] = newValue }
    }
}

@MainActor
final class SolarThemeStore: ObservableObject {
    @Published private(set) var applied: SolarThemePreferences
    private let defaults: UserDefaults
    private let key = "solarThemePreferencesV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(SolarThemePreferences.self, from: data) {
            applied = value
        } else { applied = .solarDefault }
    }

    func apply(_ preferences: SolarThemePreferences) {
        applied = preferences
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
    }

    func reset() { apply(.solarDefault) }

    var preferredColorScheme: ColorScheme? {
        switch applied.appearance { case .system: nil; case .dark: .dark; case .light: .light }
    }
}

enum SolarColor {
    static let background = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let surface = Color(red: 0.10, green: 0.105, blue: 0.125)
    static let elevated = Color(red: 0.14, green: 0.145, blue: 0.17)
    static let sun = Color(red: 1.0, green: 0.624, blue: 0.184)
    static let gold = Color(red: 1.0, green: 0.843, blue: 0.471)
    static let status = Color(red: 0.275, green: 0.82, blue: 0.88)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.66)
}

enum SolarSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum SolarRadius {
    static let card: CGFloat = 22
    static let control: CGFloat = 14
}

struct SolarBackground: View {
    @Environment(\.solarTheme) private var theme
    var body: some View {
        ZStack {
            theme.background
            RadialGradient(
                colors: [theme.accent.opacity(theme.highContrast ? 0.18 : 0.11), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 430
            )
        }
        .ignoresSafeArea()
    }
}

struct SolarCard<Content: View>: View {
    @Environment(\.solarTheme) private var theme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(SolarSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: SolarRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SolarRadius.card, style: .continuous)
                    .stroke(Color.white.opacity(theme.highContrast ? 0.30 : 0.07), lineWidth: theme.highContrast ? 1.5 : 1)
            }
    }
}

struct SolarOrbitMark: View {
    @Environment(\.solarTheme) private var theme
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [theme.secondaryAccent, theme.accent],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: size * 0.4
                    )
                )
                .frame(width: size * 0.38, height: size * 0.38)
                .shadow(color: theme.accent.opacity(0.7), radius: size * 0.18)

            Ellipse()
                .stroke(theme.secondaryAccent, lineWidth: max(2, size * 0.035))
                .frame(width: size, height: size * 0.54)
                .rotationEffect(.degrees(-24))

            Circle()
                .fill(theme.secondaryAccent)
                .frame(width: size * 0.12, height: size * 0.12)
                .offset(x: size * 0.39, y: -size * 0.11)
        }
        .accessibilityHidden(true)
    }
}

struct MetricPill: View {
    @Environment(\.solarTheme) private var theme
    let result: MetricResult
    let systemImage: String

    private var displayValue: String {
        guard let value = result.value else { return "—" }
        let formatted = value.formatted(.number.precision(.fractionLength(0...1)))
        return result.unit.isEmpty ? formatted : "\(formatted) \(result.unit)"
    }

    var body: some View {
        HStack(spacing: SolarSpace.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.secondaryAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Text(displayValue)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(theme.primaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SolarSpace.md)
        .background(theme.elevated, in: RoundedRectangle(cornerRadius: SolarRadius.control, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.name)
        .accessibilityValue(result.value == nil ? "Unavailable" : displayValue)
        .accessibilityHint(result.reasons.first ?? "\(result.classification.rawValue), \(result.quality.rawValue) quality")
    }
}
