import SwiftUI

struct AppearanceLabView: View {
    @EnvironmentObject private var themeStore: SolarThemeStore
    @State private var draft: SolarThemePreferences

    init(initial: SolarThemePreferences? = nil) {
        _draft = State(initialValue: initial ?? .solarDefault)
    }

    var body: some View {
        Form {
            Section("Canvas") {
                Picker("Background", selection: $draft.background) {
                    ForEach(SolarBackgroundPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Accent", selection: $draft.accent) {
                    ForEach(SolarAccentPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Appearance", selection: $draft.appearance) {
                    ForEach(SolarAppearancePreference.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("High contrast", isOn: $draft.highContrast)
                Toggle("Reduced animation", isOn: $draft.reducedAnimation)
            }

            Section("Preview gallery") {
                AppearancePreviewGallery()
                    .environment(\.solarTheme, SolarThemePalette(draft))
                    .preferredColorScheme(draftColorScheme)
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
            }

            Section {
                Button("Apply Theme") { themeStore.apply(draft) }
                    .buttonStyle(SolarPrimaryButtonStyle())
                    .accessibilityIdentifier("appearance.apply")
                Button("Reset to Solar Default") {
                    draft = .solarDefault
                    themeStore.reset()
                }
                .accessibilityIdentifier("appearance.reset")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SolarThemePalette(draft).background)
        .navigationTitle("Appearance Lab")
        .onAppear { if draft == .solarDefault { draft = themeStore.applied } }
    }

    private var draftColorScheme: ColorScheme? {
        switch draft.appearance { case .system: nil; case .dark: .dark; case .light: .light }
    }
}

private struct AppearancePreviewGallery: View {
    @Environment(\.solarTheme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            previewCard("Live") {
                HStack {
                    Image(systemName: "heart.fill").foregroundStyle(theme.accent)
                    Text("142").font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                    Text("BPM").font(.caption.bold()).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Text("GOOD").font(.caption2.bold()).foregroundStyle(theme.secondaryAccent)
                }
                SolarZoneLadder(snapshot: .init(beatsPerMinute: 142, currentZone: 3, targetZone: 3), density: .compact)
            }
            previewCard("Today") {
                Label("Your day in motion", systemImage: "sun.max.fill").font(.headline).foregroundStyle(theme.primaryText)
                Text("Workout history and evidence-based Coach").font(.caption).foregroundStyle(theme.secondaryText)
            }
            previewCard("SolarZoneLadder") {
                SolarZoneLadder(snapshot: .init(beatsPerMinute: 146, currentZone: 3, targetZone: 2))
            }
            previewCard("Workout summary") {
                HStack { metric("38:12", "TIME"); metric("151", "AVG"); metric("24.6", "LOAD") }
                SolarZoneLadder(snapshot: .init(beatsPerMinute: 151, currentZone: 4, targetZone: nil), density: .compact)
            }
            previewCard("Lock Screen Live Activity") {
                HStack {
                    Image(systemName: "heart.fill").foregroundStyle(theme.accent)
                    VStack(alignment: .leading) { Text("Monitoring").bold(); Text("Zone 2 • Good signal").font(.caption).foregroundStyle(theme.secondaryText) }
                    Spacer(); Text("128").font(.title.bold().monospacedDigit()); Text("bpm").font(.caption2)
                }
            }
            previewCard("Dynamic Island") {
                HStack {
                    Image(systemName: "heart.fill").foregroundStyle(theme.accent)
                    Text("128 bpm").font(.headline.monospacedDigit())
                    Spacer()
                    HStack(spacing: 3) { ForEach(1...5, id: \.self) { z in Capsule().fill(SolarZonePalette.color(for: z).opacity(z == 2 ? 1 : 0.25)).frame(width: 18, height: z == 2 ? 8 : 5) } }
                }
                .padding(.horizontal, 8).padding(.vertical, 6).background(.black, in: Capsule())
            }
        }.padding()
    }

    private func previewCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.caption2.bold()).tracking(1.2).foregroundStyle(theme.secondaryText)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(theme.highContrast ? Color.white.opacity(0.35) : Color.white.opacity(0.08)) }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack { Text(value).font(.headline.monospacedDigit()).foregroundStyle(theme.primaryText); Text(label).font(.caption2).foregroundStyle(theme.secondaryText) }.frame(maxWidth: .infinity)
    }
}

#Preview("Solar preset") { NavigationStack { AppearanceLabView(initial: .solarDefault) }.environmentObject(SolarThemeStore()) }
#Preview("Midnight preset") { NavigationStack { AppearanceLabView(initial: .init(background: .midnight, accent: .aurora)) }.environmentObject(SolarThemeStore()) }
#Preview("Graphite preset") { NavigationStack { AppearanceLabView(initial: .init(background: .graphite, accent: .violet, highContrast: true)) }.environmentObject(SolarThemeStore()) }
