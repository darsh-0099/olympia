import Charts
import SwiftUI

private struct OlympiaProgressPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct OlympiaProgressView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Environment(\.olympiaColors) private var colors
    @AppStorage("olympia.units") private var units = "lb"
    @State private var category = "Push"
    @State private var exercise = ""
    @State private var metric = "Top set"
    @State private var range = "6M"

    private var exerciseNames: [String] {
        let names = store.historyExercises()
        return names.filter { categoryFor($0) == category }
    }

    private var points: [OlympiaProgressPoint] {
        let from = Calendar.current.date(byAdding: .day, value: -daysInRange, to: .now) ?? .distantPast
        if category == "Weight" {
            return store.weights.filter { $0.measuredAt >= from }
                .map { OlympiaProgressPoint(date: $0.measuredAt, value: units == "kg" ? $0.pounds / 2.2046226218 : $0.pounds) }
        }
        let key = normalized(exercise)
        return store.sessions.filter { $0.startedAt >= from }.compactMap { session in
            let sets = session.completedSets.filter { normalized($0.exerciseName) == key }
            guard !sets.isEmpty else { return nil }
            let value: Double
            if metric == "Top set" { value = sets.compactMap(\.weightPounds).max() ?? 0 }
            else { value = sets.reduce(0) { $0 + ($1.weightPounds ?? 0) * Double($1.reps ?? 0) } }
            return OlympiaProgressPoint(date: session.startedAt,
                                        value: units == "kg" ? value / 2.2046226218 : value)
        }.sorted { $0.date < $1.date }
    }

    private var daysInRange: Int {
        switch range { case "7D": 7; case "1M": 31; case "3M": 93; case "6M": 186; default: 366 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("YOUR NUMBERS").font(.caption2.bold()).tracking(1.5).foregroundStyle(colors.muted)
                        Text("Progress").font(.largeTitle.bold()).foregroundStyle(colors.text)
                    }
                    Picker("Category", selection: $category) {
                        ForEach(["Push", "Pull", "Legs", "Weight"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    if category != "Weight" {
                        OlympiaCard {
                            HStack {
                                Text("Exercise").font(.caption).foregroundStyle(colors.muted)
                                Spacer()
                                Picker("Exercise", selection: $exercise) {
                                    ForEach(exerciseNames, id: \.self) { Text($0).tag($0) }
                                }.tint(colors.text)
                            }
                        }
                        Picker("Metric", selection: $metric) {
                            Text("Top set").tag("Top set")
                            Text("Total volume").tag("Total volume")
                        }.pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category == "Weight" ? "Body weight" : exercise)
                            .font(.caption).foregroundStyle(colors.muted)
                        if let last = points.last {
                            Text(String(format: "%.1f %@", last.value, units))
                                .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(colors.text)
                        } else {
                            Text("No recorded data").font(.title3.bold()).foregroundStyle(colors.text)
                        }
                    }.padding(.top, 8)
                    OlympiaCard {
                        if points.isEmpty {
                            ContentUnavailableView("No data for this selection", systemImage: "chart.xyaxis.line",
                                                   description: Text("Import workouts or record sets to see progress."))
                                .frame(height: 190)
                        } else {
                            Chart(points) { point in
                                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                                    .interpolationMethod(.catmullRom).foregroundStyle(colors.accent)
                                PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                                    .foregroundStyle(colors.accent)
                            }.chartXScale(domain: (Calendar.current.date(byAdding: .day, value: -daysInRange, to: .now) ?? .now)...Date())
                                .frame(height: 215)
                        }
                    }
                    Picker("Time range", selection: $range) {
                        ForEach(["7D", "1M", "3M", "6M", "1Y"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    if points.count > 1 {
                        OlympiaCard {
                            let change = points.last!.value - points.first!.value
                            Label(String(format: "%@%.1f %@ since your first point in this range",
                                         change >= 0 ? "+" : "", change, units),
                                  systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.subheadline.bold()).foregroundStyle(colors.text)
                        }
                    }
                }.padding(20)
            }.background(colors.background).toolbar(.hidden, for: .navigationBar)
                .onAppear { ensureSelection() }
                .onChange(of: category) { _, _ in ensureSelection() }
                .onChange(of: store.sessions.count) { _, _ in ensureSelection() }
        }
    }

    private func ensureSelection() {
        if !exerciseNames.contains(exercise) { exercise = exerciseNames.first ?? "" }
    }

    private func normalized(_ name: String) -> String { olympiaExerciseKey(name) }

    private func categoryFor(_ name: String) -> String {
        let value = normalized(name)
        if ["squat", "leg", "quad", "hamstring", "calf", "glute", "lunge", "deadlift", "hipthrust"].contains(where: value.contains) { return "Legs" }
        if ["row", "pull", "back", "lat", "bicep", "curl", "facepull", "rear"].contains(where: value.contains) { return "Pull" }
        return "Push"
    }
}
