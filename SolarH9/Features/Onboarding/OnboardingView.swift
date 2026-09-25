import SwiftUI

struct OnboardingView: View {
    @Environment(\.solarTheme) private var theme
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int

    init(initialPage: Int = 0) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        ZStack {
            SolarBackground()

            ScrollView {
                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? SolarSpace.md : SolarSpace.xl) {
                    SolarOrbitMark(size: dynamicTypeSize.isAccessibilitySize ? 72 : 116)
                        .accessibilityLabel("SolarH9")

                    VStack(spacing: SolarSpace.md) {
                        Text(page == 0 ? "Your signal, kept close." : "Start with your H9—or a demo.")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(theme.primaryText)

                        Text(page == 0
                             ? "SolarH9 records heart rate and beat-to-beat RR intervals locally on this iPhone. No account, ads, or tracking."
                             : "Bluetooth is used only to connect to a compatible chest strap and record sessions you start. Demo data always stays separate from your real trends.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, SolarSpace.lg)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? SolarSpace.md : 72)
                .padding(.bottom, 190)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: SolarSpace.md) {
                if page == 0 {
                    Button("Continue") {
                        withAnimation(reduceMotion ? nil : .snappy) { page = 1 }
                    }
                    .buttonStyle(SolarPrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.continue")
                } else {
                    VStack(spacing: SolarSpace.md) {
                        Button("Connect H9") {
                            appModel.completeOnboarding(useDemoMode: false)
                        }
                        .buttonStyle(SolarPrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.connectH9")

                        Button("Try demo mode") {
                            appModel.completeOnboarding(useDemoMode: true)
                        }
                        .buttonStyle(SolarSecondaryButtonStyle())
                        .accessibilityIdentifier("onboarding.demoMode")
                    }
                }

                Text("SolarH9 is a wellness app, not a medical device or emergency monitor.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, SolarSpace.lg)
                .padding(.vertical, SolarSpace.md)
                .background(.ultraThinMaterial)
            }
        }
    }
}

struct SolarPrimaryButtonStyle: ButtonStyle {
    @Environment(\.solarTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: SolarRadius.control, style: .continuous))
    }
}

struct SolarSecondaryButtonStyle: ButtonStyle {
    @Environment(\.solarTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(theme.secondaryAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(theme.surface.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: SolarRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SolarRadius.control, style: .continuous)
                    .stroke(theme.secondaryAccent.opacity(0.45), lineWidth: 1)
            }
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.onboarding")!))
}

#Preview("Onboarding choices, AX5") {
    OnboardingView(initialPage: 1)
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.onboarding.choices")!))
        .environment(\.dynamicTypeSize, .accessibility5)
}
