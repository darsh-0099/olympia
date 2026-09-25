import Charts
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    init(olympiaHex: String) {
        let value = Int(olympiaHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x63C7FF
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }
}

struct OlympiaColors {
    let isLight: Bool
    let accent: Color
    var background: Color { isLight ? Color(olympiaHex: "#F4F7FA") : Color(olympiaHex: "#0B0D0F") }
    var surface: Color { isLight ? .white : Color(olympiaHex: "#151A1F") }
    var secondarySurface: Color { isLight ? Color(olympiaHex: "#EAF0F5") : Color(olympiaHex: "#1C252E") }
    var text: Color { isLight ? Color(olympiaHex: "#13212D") : Color(olympiaHex: "#F5F8FA") }
    var muted: Color { isLight ? Color(olympiaHex: "#657482") : Color(olympiaHex: "#97A4AF") }
    var border: Color { isLight ? Color(olympiaHex: "#D4DFE7") : Color(olympiaHex: "#2B3843") }
}

private struct OlympiaColorsKey: EnvironmentKey {
    static let defaultValue = OlympiaColors(isLight: false, accent: Color(olympiaHex: "#63C7FF"))
}

extension EnvironmentValues {
    var olympiaColors: OlympiaColors {
        get { self[OlympiaColorsKey.self] }
        set { self[OlympiaColorsKey.self] = newValue }
    }
}

struct OlympiaCard<Content: View>: View {
    @Environment(\.olympiaColors) private var colors
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(colors.border, lineWidth: 1))
    }
}

struct OlympiaRootView: View {
    private enum QuickSheet: String, Identifiable {
        case workout, weight, sensor
        var id: String { rawValue }
    }
    @ObservedObject var store: OlympiaTrainingStore
    @StateObject private var engine: OlympiaWorkoutEngine
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("olympia.theme") private var theme = "system"
    @AppStorage("olympia.accent") private var accent = "sky"
    @State private var selection = 0
    @State private var showQuickAction = false
    @State private var quickSheet: QuickSheet?

    init(store: OlympiaTrainingStore) {
        self.store = store
        _engine = StateObject(wrappedValue: OlympiaWorkoutEngine(store: store))
    }

    private var colors: OlympiaColors {
        let isLight = theme == "light" || (theme == "system" && systemScheme == .light)
        let accents = ["sky": "#63C7FF", "emerald": "#63DF86", "violet": "#AD8CFF", "sunset": "#FF9D72"]
        return OlympiaColors(isLight: isLight, accent: Color(olympiaHex: accents[accent] ?? "#63C7FF"))
    }

    var body: some View {
        TabView(selection: $selection) {
            OlympiaHomeView(store: store, engine: engine, onOpenSettings: { selection = 4 })
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
            OlympiaProgramView(store: store, engine: engine).tabItem { Label("Program", systemImage: "list.bullet.rectangle") }.tag(1)
            Color.clear.tabItem { Label("Add", systemImage: "plus.square.fill") }.tag(2)
            OlympiaProgressView(store: store).tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }.tag(3)
            OlympiaSettingsView(store: store).tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
        .tint(colors.accent)
        .onChange(of: selection) { oldValue, newValue in
            if newValue == 2 { selection = oldValue; showQuickAction = true }
        }
        .confirmationDialog("Quick action", isPresented: $showQuickAction) {
            Button("Create workout") { quickSheet = .workout }
            Button("Log body weight") { quickSheet = .weight }
            Button("Connect heart-rate sensor") { quickSheet = .sensor }
        }
        .sheet(item: $quickSheet) { choice in
            switch choice {
            case .workout: OlympiaWorkoutEditor(store: store, workout: nil)
            case .weight: OlympiaWeightEntryView(store: store)
            case .sensor: LiveView()
            }
        }
        .environment(\.olympiaColors, colors)
        .preferredColorScheme(colors.isLight ? .light : .dark)
        .fullScreenCover(isPresented: Binding(get: { engine.isActive }, set: { _ in })) {
            OlympiaActiveWorkoutView(store: store, engine: engine)
                .environment(\.olympiaColors, colors)
                .preferredColorScheme(colors.isLight ? .light : .dark)
                .interactiveDismissDisabled()
        }
        .alert("Olympia", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private func olympiaDate(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()
}

private func olympiaDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

struct OlympiaHomeView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @ObservedObject var engine: OlympiaWorkoutEngine
    let onOpenSettings: () -> Void
    @Environment(\.olympiaColors) private var colors
    @AppStorage("olympia.units") private var units = "lb"
    @AppStorage("olympia.displayName") private var displayName = ""
    @State private var showCalendar = false
    @State private var showWeightEntry = false
    @State private var showHistory = false
    @State private var selectedDate = Date()
    @State private var month = Date()
    @State private var selectedSession: OlympiaTrainingSession?
    @State private var greeting = "Ready to work?"

    private var todayWorkouts: [OlympiaWorkoutTemplate] { store.scheduledWorkouts(on: .now) }
    private var lastSession: OlympiaTrainingSession? { store.sessions.first { ["completed", "partial", "imported"].contains($0.status) } }
    private var latestWeight: OlympiaBodyWeight? { store.weights.last }
    private var completedDays: Set<Date> {
        Set(store.sessions.filter { ["completed", "partial", "imported"].contains($0.status) }
            .map { Calendar.current.startOfDay(for: $0.startedAt) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(olympiaDate(.now)).font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(colors.muted)
                            Text(greeting).font(.system(size: 29, weight: .bold, design: .rounded)).foregroundStyle(colors.text)
                        }
                        Spacer()
                        Button(action: onOpenSettings) {
                            Image("OlympiaMark").resizable().scaledToFit().frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.accessibilityLabel("Open profile and settings")
                    }.padding(.top, 6)

                    OlympiaCard {
                        VStack(alignment: .leading, spacing: 17) {
                            HStack {
                                Label(streak == 0 ? "No streak yet" : "\(streak) day streak", systemImage: "arrow.up.right")
                                    .font(.subheadline.bold()).foregroundStyle(colors.text)
                                Spacer()
                                Text("Best: \(bestStreak) days").font(.caption).foregroundStyle(colors.muted)
                            }
                            weekStrip
                            Button(showCalendar ? "Hide monthly plan  ⌃" : "View monthly plan  ⌄") {
                                withAnimation(.smooth(duration: 0.4)) { showCalendar.toggle(); selectedDate = .now; month = .now }
                            }.font(.caption).frame(maxWidth: .infinity).foregroundStyle(colors.muted)
                        }
                    }

                    if showCalendar {
                        OlympiaMonthCalendar(store: store, month: $month, selectedDate: $selectedDate,
                                            selectedSession: $selectedSession)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                    }

                    OlympiaCard {
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("TODAY'S WORKOUT").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(colors.muted)
                                Text(todayWorkouts.first?.name ?? "Rest day")
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(colors.text)
                                Text(todayWorkouts.first.map { "\($0.exercises.count) exercises · \($0.exercises.reduce(0) { $0 + $1.sets }) sets" }
                                     ?? "Nothing scheduled today")
                                    .font(.caption).foregroundStyle(colors.muted)
                            }
                            Spacer(minLength: 4)
                            if let workout = todayWorkouts.first {
                                Button("Start  →") { engine.start(workout) }
                                    .buttonStyle(.borderedProminent).tint(colors.accent)
                                    .foregroundStyle(colors.isLight ? .white : .black)
                                    .contextMenu {
                                        Button("Postpone plan one day", systemImage: "calendar.badge.clock") {
                                            store.postponeRotationOneDay()
                                        }
                                    }
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BODY WEIGHT").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(colors.muted)
                            Text(weightLabel).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(colors.text)
                        }
                        Spacer()
                        Button("+ Log weight") { showWeightEntry = true }.font(.caption.bold()).foregroundStyle(colors.accent)
                    }.padding(.top, 12)

                    OlympiaCard {
                        if store.weights.count > 1 {
                            Chart(store.weights) { entry in
                                LineMark(x: .value("Date", entry.measuredAt),
                                         y: .value("Weight", units == "kg" ? entry.pounds / 2.2046226218 : entry.pounds))
                                    .foregroundStyle(colors.accent).interpolationMethod(.catmullRom)
                            }.frame(height: 130)
                        } else {
                            Text("Your weight trend appears here after two entries.")
                                .font(.caption).foregroundStyle(colors.muted).frame(height: 100)
                        }
                    }

                    HStack {
                        Text("Last workout").font(.headline).foregroundStyle(colors.text)
                        Spacer()
                        Button("View all") { showHistory = true }.font(.caption.bold()).foregroundStyle(colors.accent)
                    }.padding(.top, 12)
                    if let lastSession {
                        Button { selectedSession = lastSession } label: {
                            OlympiaCard {
                                HStack {
                                    Image(systemName: "figure.strengthtraining.traditional")
                                        .frame(width: 38, height: 38).background(colors.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(lastSession.name).font(.subheadline.bold())
                                        Text(lastSession.startedAt.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(colors.muted)
                                    }
                                    Spacer()
                                    Text("\(lastSession.completedSets.count) sets").font(.caption).foregroundStyle(colors.muted)
                                }.foregroundStyle(colors.text)
                            }
                        }.buttonStyle(.plain)
                        OlympiaCard {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("TRAINING OVERVIEW", systemImage: "sparkles")
                                    .font(.caption.bold()).foregroundStyle(colors.accent)
                                Text("\(lastSession.completedSets.count) sets recorded in your last workout. Review your top sets in Progress and aim to improve one set at a time.")
                                    .font(.caption).foregroundStyle(colors.muted)
                            }
                        }
                    } else {
                        OlympiaCard { Text("Complete or import a workout to build your history.").font(.caption).foregroundStyle(colors.muted) }
                    }
                }.padding(20).padding(.bottom, 18)
            }
            .background(colors.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWeightEntry) { OlympiaWeightEntryView(store: store) }
            .sheet(isPresented: $showHistory) { OlympiaHistoryView(store: store) }
            .sheet(item: $selectedSession) { OlympiaSessionDetailView(store: store, session: $0) }
            .onAppear {
                let named = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let options = [named.isEmpty ? "Welcome back" : "Welcome back, \(named)",
                               "Time to work", "Let's get it", "Great workout incoming",
                               "Nice to see you", "Howdy, partner"]
                greeting = options.randomElement() ?? "Ready to work?"
            }
        }
    }

    private var weightLabel: String {
        guard let latestWeight else { return "Not logged" }
        return String(format: "%.1f %@", units == "kg" ? latestWeight.pounds / 2.2046226218 : latestWeight.pounds, units)
    }

    private var weekStrip: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -mondayOffset, to: today) ?? today
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: monday) ?? today
                VStack(spacing: 6) {
                    Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(colors.muted)
                    Text("\(calendar.component(.day, from: date))")
                        .font(.caption.bold()).frame(maxWidth: .infinity).frame(height: 38)
                        .background(completedDays.contains(date) ? colors.accent : colors.secondarySurface,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(colors.text)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(calendar.isDateInToday(date) ? colors.accent : .clear))
                }
            }
        }
    }

    private var streak: Int {
        var day = Calendar.current.startOfDay(for: .now)
        if !completedDays.contains(day) { day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while completedDays.contains(day) {
            count += 1
            day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86400)
        }
        return count
    }

    private var bestStreak: Int {
        let dates = completedDays.sorted()
        var best = 0, run = 0
        var previous: Date?
        for date in dates {
            if let previous, let next = Calendar.current.date(byAdding: .day, value: 1, to: previous),
               Calendar.current.isDate(date, inSameDayAs: next) { run += 1 }
            else { run = 1 }
            best = max(best, run); previous = date
        }
        return best
    }
}
