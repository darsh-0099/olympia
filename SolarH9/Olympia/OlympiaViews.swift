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
    var background: Color { isLight ? Color(olympiaHex: "#F5F2EC") : Color(olympiaHex: "#090A0A") }
    var surface: Color { isLight ? .white : Color(olympiaHex: "#141515") }
    var secondarySurface: Color { isLight ? Color(olympiaHex: "#EAE6DF") : Color(olympiaHex: "#202121") }
    var text: Color { isLight ? Color(olympiaHex: "#20211F") : Color(olympiaHex: "#F5F0E7") }
    var muted: Color { isLight ? Color(olympiaHex: "#686861") : Color(olympiaHex: "#B2B1AA") }
    var border: Color { isLight ? Color(olympiaHex: "#DBD7D0") : Color(olympiaHex: "#30312F") }
    static let ember = Color(olympiaHex: "#FF6B2C")
    static let cream = Color(olympiaHex: "#F5F0E7")
}

private struct OlympiaColorsKey: EnvironmentKey {
    static let defaultValue = OlympiaColors(isLight: false, accent: OlympiaColors.ember)
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
    @AppStorage("olympia.theme") private var theme = "dark"
    @AppStorage("olympia.accent") private var accent = "ember"
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection = 0
    @State private var showQuickAction = false
    @State private var quickSheet: QuickSheet?

    init(store: OlympiaTrainingStore) {
        self.store = store
        _engine = StateObject(wrappedValue: OlympiaWorkoutEngine(store: store))
    }

    private var colors: OlympiaColors {
        let isLight = theme == "light" || (theme == "system" && systemScheme == .light)
        let accents = ["ember": "#FF6B2C", "sky": "#63C7FF", "emerald": "#63DF86", "violet": "#AD8CFF", "sunset": "#FF9D72"]
        return OlympiaColors(isLight: isLight, accent: Color(olympiaHex: accents[accent] ?? "#FF6B2C"))
    }

    var body: some View {
        TabView(selection: $selection) {
            OlympiaHomeView(store: store, engine: engine, onOpenSettings: { selection = 4 },
                            onOpenProgram: { selection = 1 }, onQuickAction: { showQuickAction = true })
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
                .toolbar(.hidden, for: .tabBar)
            OlympiaProgramView(store: store, engine: engine).tabItem { Label("Program", systemImage: "list.bullet.rectangle") }.tag(1)
                .toolbar(.hidden, for: .tabBar)
            OlympiaProgressView(store: store).tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }.tag(3)
                .toolbar(.hidden, for: .tabBar)
            OlympiaSettingsView(store: store).tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
                .toolbar(.hidden, for: .tabBar)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { navigationDock }
        .tint(colors.accent)
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
        .preferredColorScheme(theme == "system" ? nil : (colors.isLight ? .light : .dark))
        .fullScreenCover(isPresented: Binding(get: { engine.isActive }, set: { _ in })) {
            OlympiaActiveWorkoutView(store: store, engine: engine)
                .environment(\.olympiaColors, colors)
                .preferredColorScheme(theme == "system" ? nil : (colors.isLight ? .light : .dark))
                .interactiveDismissDisabled()
        }
        .alert("Olympia", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var navigationDock: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                dockTab("Home", icon: "house.fill", tag: 0)
                dockTab("Program", icon: "dumbbell.fill", tag: 1)
                dockTab("Progress", icon: "chart.bar.fill", tag: 3)
                dockTab("Settings", icon: "gearshape", tag: 4)
            }
            .padding(5)
            .background {
                Capsule().fill(reduceTransparency ? AnyShapeStyle(colors.surface) : AnyShapeStyle(.ultraThinMaterial))
            }
            .overlay(Capsule().stroke(colors.text.opacity(0.16), lineWidth: 1))

            Button {
                if let workout = store.scheduledWorkouts(on: .now).first { engine.start(workout) }
                else { selection = 1 }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 23, weight: .bold)).foregroundStyle(OlympiaColors.ember)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(colors.surface.gradient))
                    .overlay(Circle().stroke(OlympiaColors.ember.opacity(0.55), lineWidth: 1))
                    .shadow(color: OlympiaColors.ember.opacity(0.18), radius: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.scheduledWorkouts(on: .now).isEmpty ? "Choose a workout" : "Start today's workout")
            .contextMenu {
                Button("Create workout", systemImage: "plus") { quickSheet = .workout }
                Button("Log body weight", systemImage: "scalemass") { quickSheet = .weight }
                Button("Connect heart-rate sensor", systemImage: "heart") { quickSheet = .sensor }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(LinearGradient(colors: [colors.background.opacity(0), colors.background], startPoint: .top, endPoint: .bottom))
    }

    private func dockTab(_ title: String, icon: String, tag: Int) -> some View {
        Button { selection = tag } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(selection == tag ? colors.text : colors.muted)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(selection == tag ? colors.text.opacity(0.12) : .clear, in: Capsule())
            .overlay(Capsule().stroke(selection == tag ? colors.text.opacity(0.25) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == tag ? .isSelected : [])
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
    let onOpenProgram: () -> Void
    let onQuickAction: () -> Void
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    workoutHero
                        .padding(.horizontal, -20)

                        VStack(alignment: .leading, spacing: 14) {
                            weekStrip
                            HStack {
                                Label(streak == 0 ? "No streak yet" : "\(streak) day streak", systemImage: "arrow.up.right")
                                    .font(.caption).foregroundStyle(colors.muted)
                                Spacer()
                                Text("Best: \(bestStreak) days").font(.caption).foregroundStyle(colors.muted)
                            }
                            Button(showCalendar ? "Hide monthly plan  ⌃" : "View monthly plan  ⌄") {
                                withAnimation(.smooth(duration: 0.4)) { showCalendar.toggle(); selectedDate = .now; month = .now }
                            }.font(.caption).frame(maxWidth: .infinity).foregroundStyle(colors.muted)
                        }

                    if showCalendar {
                        OlympiaMonthCalendar(store: store, month: $month, selectedDate: $selectedDate,
                                            selectedSession: $selectedSession)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                    }

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BODY WEIGHT").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(colors.muted)
                            Text(weightLabel).font(.system(size: 30, weight: .heavy)).fontWidth(.condensed).foregroundStyle(colors.text)
                        }
                        Spacer()
                        Button { showWeightEntry = true } label: {
                            Label("Log", systemImage: "plus").font(.subheadline)
                                .padding(.horizontal, 18).padding(.vertical, 13)
                                .background(colors.secondarySurface, in: Capsule())
                                .overlay(Capsule().stroke(colors.border, lineWidth: 1))
                        }.buttonStyle(.plain).foregroundStyle(colors.text).accessibilityLabel("Log body weight")
                    }.padding(.top, 18)

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
                }.padding(.horizontal, 20).padding(.bottom, 18)
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

    private var workoutHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onOpenSettings) {
                    Image("OlympiaMark").resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.accessibilityLabel("Open profile and settings")
                Spacer(minLength: 0)
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
                    .font(.system(size: 11, weight: .medium)).tracking(2.5)
                    .foregroundStyle(OlympiaColors.cream)
                Spacer(minLength: 0)
                Button(action: onQuickAction) {
                    Image(systemName: "plus").font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.28), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                }.foregroundStyle(OlympiaColors.cream).accessibilityLabel("Quick actions")
            }
            .padding(.top, 12)

            Text(greeting).font(.caption).foregroundStyle(OlympiaColors.cream.opacity(0.8))
                .padding(.top, 22)

            Text((todayWorkouts.first?.name ?? "Rest day").uppercased())
                .font(.custom("AvenirNextCondensed-Heavy", size: dynamicTypeSize.isAccessibilitySize ? 50 : 88, relativeTo: .largeTitle))
                .tracking(-2)
                .foregroundStyle(OlympiaColors.cream)
                .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)

            Text(todayWorkouts.first.map { "\($0.exercises.count) exercises    \($0.exercises.reduce(0) { $0 + $1.sets }) sets" }
                 ?? "Nothing scheduled. Make space to recover.")
                .font(.subheadline).foregroundStyle(OlympiaColors.cream)
                .padding(.top, 14)

            Spacer(minLength: 54)

            Button {
                if let workout = todayWorkouts.first { engine.start(workout) }
                else { onOpenProgram() }
            } label: {
                HStack {
                    Spacer()
                    Text(todayWorkouts.isEmpty ? "Explore your program" : "Start workout")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 22).padding(.vertical, 19)
                .background(LinearGradient(colors: [OlympiaColors.ember, Color(olympiaHex: "#FF8A46")],
                                           startPoint: .leading, endPoint: .trailing), in: Capsule())
                .overlay(Capsule().stroke(Color(olympiaHex: "#FFB16B").opacity(0.7), lineWidth: 1))
                .shadow(color: OlympiaColors.ember.opacity(0.22), radius: 18, y: 5)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !todayWorkouts.isEmpty {
                    Button("Postpone plan one day", systemImage: "calendar.badge.clock") { store.postponeRotationOneDay() }
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 460, alignment: .top)
        .background {
            GeometryReader { geometry in
                Image("OlympiaMatterhorn").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                                   .init(color: .black.opacity(0.48), location: 0.42),
                                                   .init(color: .black.opacity(0.65), location: 1)],
                                            startPoint: .top, endPoint: .bottom))
                    .overlay(LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .leading, endPoint: .trailing))
                    // Keep the photograph dark behind cream text in every theme;
                    // only the button's bottom edge fades into the page background.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, colors.background], startPoint: .top, endPoint: .bottom)
                            .frame(height: 64)
                    }
            }.accessibilityHidden(true)
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
                        .font(.body).frame(maxWidth: .infinity).frame(height: 42)
                        .background(completedDays.contains(date) ? colors.accent.opacity(0.2) : .clear,
                                    in: Circle())
                        .foregroundStyle(colors.text)
                        .overlay(Circle().stroke(calendar.isDateInToday(date) ? colors.accent : .clear, lineWidth: 1.5))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                .accessibilityValue((calendar.isDateInToday(date) ? "Today. " : "") + (completedDays.contains(date) ? "Workout completed" : ""))
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
