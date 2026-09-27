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
    var background: Color { isLight ? Color(olympiaHex: "#F5F5F5") : Color(olympiaHex: "#080808") }
    var surface: Color { isLight ? .white : Color(olympiaHex: "#171717") }
    var secondarySurface: Color { isLight ? Color(olympiaHex: "#EAEAEA") : Color(olympiaHex: "#242424") }
    var text: Color { isLight ? Color(olympiaHex: "#202020") : .white }
    var muted: Color { isLight ? Color(olympiaHex: "#686868") : Color(olympiaHex: "#939393") }
    var border: Color { isLight ? Color(olympiaHex: "#DEDEDE") : Color(olympiaHex: "#292929") }
    static let blue = Color(olympiaHex: "#2697FF")
    static let ember = Color(olympiaHex: "#FF6B2C")
    static let cream = Color(olympiaHex: "#F5F0E7")
}

private struct OlympiaColorsKey: EnvironmentKey {
    static let defaultValue = OlympiaColors(isLight: false, accent: OlympiaColors.blue)
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
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(colors.border, lineWidth: 0.75))
    }
}

/// A brief, interruptible response shared by the compact blueprint controls.
struct OlympiaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
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
    @AppStorage("olympia.accent") private var accent = "sky"
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
        let accents = ["ember": "#FF6B2C", "sky": "#2697FF", "emerald": "#63DF86", "violet": "#AD8CFF", "sunset": "#FF9D72"]
        return OlympiaColors(isLight: isLight, accent: Color(olympiaHex: accents[accent] ?? "#2697FF"))
    }

    var body: some View {
        TabView(selection: $selection) {
            OlympiaHomeView(store: store, engine: engine,
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
        HStack(spacing: 4) {
            dockTab("Home", icon: "house.fill", tag: 0)
            dockTab("Program", icon: "calendar", tag: 1)
            Button { showQuickAction = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(colors.text)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(colors.secondarySurface, in: Capsule())
            }
            .buttonStyle(OlympiaPressStyle())
            .accessibilityLabel("Quick actions")
            .contextMenu {
                Button("Create workout", systemImage: "plus") { quickSheet = .workout }
                Button("Log body weight", systemImage: "scalemass") { quickSheet = .weight }
                Button("Connect heart-rate sensor", systemImage: "heart") { quickSheet = .sensor }
            }
            dockTab("Progress", icon: "chart.bar.fill", tag: 3)
            dockTab("Settings", icon: "gearshape", tag: 4)
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
        .background(colors.background)
        .overlay(alignment: .top) { Rectangle().fill(colors.border.opacity(0.6)).frame(height: 0.5) }
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
        }
        .buttonStyle(OlympiaPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == tag ? .isSelected : [])
    }
}

struct OlympiaHomeView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @ObservedObject var engine: OlympiaWorkoutEngine
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
    @State private var editingWorkout: OlympiaWorkoutTemplate?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    homeHeader
                        VStack(alignment: .leading, spacing: 14) {
                            weekStrip
                            workoutHero
                            HStack {
                                Label(streak == 0 ? "No streak yet" : "\(streak) day streak", systemImage: "arrow.up.right")
                                    .font(.caption).foregroundStyle(colors.muted)
                                Spacer()
                                Text("Best: \(bestStreak) days").font(.caption).foregroundStyle(colors.muted)
                            }
                            Button(showCalendar ? "Hide monthly plan  ⌃" : "View monthly plan  ⌄") {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showCalendar.toggle(); selectedDate = .now; month = .now }
                            }.font(.caption).frame(maxWidth: .infinity).foregroundStyle(colors.muted)
                        }

                    if showCalendar {
                        OlympiaMonthCalendar(store: store, month: $month, selectedDate: $selectedDate,
                                            selectedSession: $selectedSession)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                    }

                    workoutGrid

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
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .background(colors.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWeightEntry) { OlympiaWeightEntryView(store: store) }
            .sheet(isPresented: $showHistory) { OlympiaHistoryView(store: store) }
            .sheet(item: $selectedSession) { OlympiaSessionDetailView(store: store, session: $0) }
            .sheet(item: $editingWorkout) { OlympiaWorkoutEditor(store: store, workout: $0) }
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("OLYMPIA").font(.system(size: 10, weight: .bold)).tracking(2.5)
                    .foregroundStyle(colors.muted)
                (Text("Hey, ").foregroundColor(colors.text) +
                 Text(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "athlete" : displayName)
                    .foregroundColor(colors.muted))
                    .font(.title2.bold())
            }
            Spacer()
            Image("OlympiaMark").resizable().scaledToFit().frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    private var workoutHero: some View {
        let isRestDay = todayWorkouts.isEmpty
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isRestDay ? "Rest day" : "Training day").font(.headline)
                Text(isRestDay ? "No workout planned today" : todayWorkouts.map(\.name).joined(separator: " · "))
                    .font(.caption).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                if let workout = todayWorkouts.first { engine.start(workout) }
                else { onOpenProgram() }
            } label: {
                Label(isRestDay ? "Plan" : "Start", systemImage: isRestDay ? "plus.circle.fill" : "play.circle.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(.black.opacity(0.18), in: Capsule())
            }
            .buttonStyle(OlympiaPressStyle())
            .accessibilityLabel(isRestDay ? "Open your program" : "Start today's workout")
            .contextMenu {
                if !isRestDay {
                    Button("Postpone plan one day", systemImage: "calendar.badge.clock") { store.postponeRotationOneDay() }
                }
            }
        }
        .foregroundStyle(isRestDay ? Color.white : Color(olympiaHex: "#382618"))
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(LinearGradient(
            colors: isRestDay ? [Color(olympiaHex: "#666CE3"), Color(olympiaHex: "#9690EC")] :
                [Color(olympiaHex: "#F4BD68"), Color(olympiaHex: "#E995A0")],
            startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 17))
    }

    private var workoutGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(colors.border).frame(height: 0.5).padding(.vertical, 4)
            HStack {
                Text("Workouts").font(.headline).foregroundStyle(colors.text)
                Spacer()
                Button("Manage", action: onOpenProgram).font(.caption.bold()).foregroundStyle(colors.muted)
                    .frame(minHeight: 44)
            }
            if store.workouts.isEmpty {
                OlympiaCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Make room for your first workout.").font(.subheadline.bold()).foregroundStyle(colors.text)
                        Text("Create a routine, plan your week, and track every set.").font(.caption).foregroundStyle(colors.muted)
                        Button("Create workout", action: onQuickAction).font(.subheadline.bold()).foregroundStyle(colors.accent)
                            .frame(minHeight: 44)
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                    ForEach(store.workouts) { workout in
                        workoutTile(workout)
                    }
                }
            }
        }
    }

    private func workoutTile(_ workout: OlympiaWorkoutTemplate) -> some View {
        let tint = Color(olympiaHex: workout.colorHex)
        let session = store.sessions.first { $0.workoutID == workout.id && ["completed", "partial", "imported"].contains($0.status) }
        let sets = session?.completedSets ?? []
        let maxReps = sets.compactMap(\.reps).max()
        let maxWeight = sets.compactMap(\.weightPounds).max()
        return Button { editingWorkout = workout } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text(workout.name).font(.subheadline.bold()).foregroundStyle(tint)
                    .lineLimit(2).frame(minHeight: 20, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last session").font(.system(size: 10)).foregroundStyle(colors.muted)
                    if let session {
                        Label(session.startedAt.formatted(.dateTime.month(.abbreviated).day()), systemImage: "calendar")
                            .font(.caption2).foregroundStyle(colors.muted)
                        Text(sets.isEmpty ? "No sets recorded" : sets.compactMap(\.reps).map(String.init).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(colors.muted).lineLimit(1)
                    } else {
                        Text("Not started yet").font(.caption2).foregroundStyle(colors.muted)
                        Text("\(workout.exercises.count) exercises · \(workout.exercises.reduce(0) { $0 + $1.sets }) sets")
                            .font(.caption2).foregroundStyle(colors.muted).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    tileMetric("\(sets.count)", label: "sets", tint: tint)
                    tileMetric(maxReps.map(String.init) ?? "—", label: "max reps", tint: tint)
                    tileMetric(maxWeight.map { String(format: "%.0f", units == "kg" ? $0 / 2.2046226218 : $0) } ?? "—",
                               label: units, tint: tint)
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis.circle").foregroundStyle(colors.muted).font(.caption)
                }.padding(.top, 3)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(colors.border, lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(OlympiaPressStyle())
        .accessibilityLabel("\(workout.name). \(sets.count) sets in last session. Edit workout.")
        .contextMenu {
            Button("Start workout", systemImage: "play.fill") { engine.start(workout) }
            Button("Edit workout", systemImage: "pencil") { editingWorkout = workout }
            if let session {
                Button("View last session", systemImage: "clock") { selectedSession = session }
            }
        }
    }

    private func tileMetric(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(colors.text)
            Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(tint)
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
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        selectedDate = date; month = date; showCalendar = true
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(calendar.isDateInToday(date) ? colors.text : colors.muted)
                        Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 8, weight: .medium)).foregroundStyle(colors.muted)
                        Circle().fill(completedDays.contains(date) ? colors.accent :
                                      (store.scheduledWorkouts(on: date).first.map { Color(olympiaHex: $0.colorHex) } ?? .clear))
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(calendar.isDateInToday(date) ? colors.secondarySurface : .clear,
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(OlympiaPressStyle())
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
