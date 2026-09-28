import Charts
import SwiftUI

private struct OlympiaProgressPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
}

struct OlympiaProgressView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Environment(\.olympiaColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("olympia.units") private var units = "lb"
    @State private var category = "Push"
    @State private var exercise = ""
    @State private var metric = "Top set"
    @State private var range = "All"

    private var exerciseNames: [String] {
        let names = store.historyExercises()
        return names.filter { categoryFor($0) == category }
    }

    private var points: [OlympiaProgressPoint] {
        let from = rangeStart ?? .distantPast
        if category == "Weight" {
            return store.weights.filter { $0.measuredAt >= from }
                .map { OlympiaProgressPoint(date: $0.measuredAt, value: units == "kg" ? $0.pounds / 2.2046226218 : $0.pounds) }
        }
        let key = normalized(exercise)
        guard !key.isEmpty else { return [] }
        let matchingSets = store.sessions.flatMap(\.completedSets).filter {
            $0.completedAt >= from && normalized($0.exerciseName) == key
        }
        let byDay = Dictionary(grouping: matchingSets) { Calendar.current.startOfDay(for: $0.completedAt) }
        return byDay.compactMap { day, sets in
            let value: Double
            if metric == "Top set" {
                guard let maximum = sets.compactMap(\.weightPounds).max() else { return nil }
                value = maximum
            } else {
                let measuredSets = sets.filter { $0.weightPounds != nil && $0.effectiveReps != nil }
                guard !measuredSets.isEmpty else { return nil }
                value = measuredSets.reduce(0) { $0 + ($1.weightPounds ?? 0) * ($1.effectiveReps ?? 0) }
            }
            return OlympiaProgressPoint(date: day,
                                        value: units == "kg" ? value / 2.2046226218 : value)
        }.sorted { $0.date < $1.date }
    }

    private var rangeStart: Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        switch range {
        case "7D": return calendar.date(byAdding: .day, value: -6, to: today)
        case "1M": return calendar.date(byAdding: .month, value: -1, to: today)
        case "3M": return calendar.date(byAdding: .month, value: -3, to: today)
        case "6M": return calendar.date(byAdding: .month, value: -6, to: today)
        case "1Y": return calendar.date(byAdding: .year, value: -1, to: today)
        default: return nil
        }
    }

    private var chartStart: Date {
        rangeStart ?? points.first?.date ?? .now
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text("Progress").font(.title2.bold()).foregroundStyle(colors.text)
                    selectionPills(["Push", "Pull", "Legs", "Weight"], selection: $category)
                    if category != "Weight" {
                        OlympiaCard {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Exercise").font(.caption).foregroundStyle(colors.muted)
                                Menu {
                                    ForEach(exerciseNames, id: \.self) { name in
                                        Button {
                                            exercise = name
                                        } label: {
                                            if name == exercise { Label(name, systemImage: "checkmark") }
                                            else { Text(name) }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(exercise.isEmpty ? "No exercises yet" : exercise)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                                    }
                                    .foregroundStyle(colors.text)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .background(colors.secondarySurface, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .disabled(exerciseNames.isEmpty)
                            }
                        }
                        selectionPills(["Top set", "Total volume"], selection: $metric)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category == "Weight" ? "Body weight" : exercise)
                            .font(.caption).foregroundStyle(colors.muted)
                        if let last = points.last {
                            Text(String(format: "%.1f %@", last.value, units))
                                .font(.system(size: 32, weight: .bold)).monospacedDigit().foregroundStyle(colors.text)
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
                            }.chartXScale(domain: chartStart...max(.now, points.last?.date ?? .now))
                                .frame(height: 215)
                        }
                    }
                    selectionPills(["7D", "1M", "3M", "6M", "1Y", "All"], selection: $range)
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
            }.scrollIndicators(.hidden)
                .background(colors.background).toolbar(.hidden, for: .navigationBar)
                .onAppear { ensureSelection() }
                .onChange(of: category) { _, _ in ensureSelection() }
                .onChange(of: store.sessions.count) { _, _ in ensureSelection() }
                .onChange(of: exerciseNames) { _, _ in ensureSelection() }
        }
    }

    private func selectionPills(_ options: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selection.wrappedValue = option }
                } label: {
                    Text(option).font(.caption.weight(.semibold))
                        .foregroundStyle(selection.wrappedValue == option ? colors.text : colors.muted)
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                        .background(selection.wrappedValue == option ? colors.secondarySurface : colors.surface, in: Capsule())
                }.buttonStyle(OlympiaPressStyle())
                    .accessibilityAddTraits(selection.wrappedValue == option ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain)
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
