import SwiftUI

struct RootTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.solarTheme) private var theme

    var body: some View {
        @Bindable var appModel = appModel

        TabView(selection: $appModel.selectedTab) {
            LiveView()
                .tag(AppModel.Tab.live)
                .tabItem { Label("Live", systemImage: "heart.circle.fill") }

            TodayView()
                .tag(AppModel.Tab.today)
                .tabItem { Label("Today", systemImage: "sun.max.fill") }

            TrendsView()
                .tag(AppModel.Tab.trends)
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }

            SettingsView()
                .tag(AppModel.Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .toolbarBackground(theme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
