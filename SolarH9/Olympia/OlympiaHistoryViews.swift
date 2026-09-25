import Charts
import SwiftUI

struct OlympiaMonthCalendar: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Binding var month: Date
    @Binding var selectedDate: Date
    @Binding var selectedSession: OlympiaTrainingSession?
    @Environment(\.olympiaColors) private var colors

    private var first: Date { Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: month)) ?? month }
    private var dayCount: Int { Calendar.current.range(of: .day, in: .month, for: month)?.count ?? 30 }
    private var offset: Int { Calendar.current.component(.weekday, from: first) - 1 }
    private var sessionsForDate: [OlympiaTrainingSession] {
        store.sessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: selectedDate) }
    }

    var body: some View {
        OlympiaCard {
            VStack(spacing: 14) {
                HStack {
                    Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.subheadline.bold()).foregroundStyle(colors.text)
                    Spacer()
                    Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                }
                HStack {
                    ForEach(["S", "M", "T", "W", "T", "F", "S"].indices, id: \.self) { index in
                        Text(["S", "M", "T", "W", "T", "F", "S"][index]).frame(maxWidth: .infinity)
                            .font(.caption2).foregroundStyle(colors.muted)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                    ForEach(0..<(offset + dayCount), id: \.self) { index in
                        if index < offset { Color.clear.frame(height: 45) }
                        else {
                            let date = Calendar.current.date(byAdding: .day, value: index - offset, to: first) ?? first
                            let planned = store.scheduledWorkouts(on: date)
                            let done = store.sessions.contains { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }
                            Button { selectedDate = date } label: {
                                VStack(spacing: 4) {
                                    Text("\(index - offset + 1)").font(.caption.bold()).foregroundStyle(colors.text)
                                    HStack(spacing: 2) {
                                        ForEach(planned.prefix(3)) { workout in
                                            Circle().fill(Color(olympiaHex: workout.colorHex)).frame(width: 4, height: 4)
                                        }
                                        if done { Circle().fill(colors.accent).frame(width: 4, height: 4) }
                                    }.frame(height: 4)
                                }.frame(maxWidth: .infinity).frame(height: 44)
                                    .background(colors.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(Calendar.current.isDate(date, inSameDayAs: selectedDate) ? colors.accent : .clear, lineWidth: 2))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(selectedDate.formatted(date: .complete, time: .omitted)).font(.caption.bold()).foregroundStyle(colors.text)
                    ForEach(sessionsForDate) { session in
                        Button { selectedSession = session } label: {
                            HStack {
                                Text(session.name)
                                Spacer()
                                Text("\(session.completedSets.count) sets")
                                Image(systemName: "chevron.right")
                            }.font(.caption).foregroundStyle(colors.accent)
                        }
                    }
                    ForEach(store.scheduledWorkouts(on: selectedDate)) { workout in
                        Label("Planned: \(workout.name)", systemImage: "calendar")
                            .font(.caption).foregroundStyle(colors.muted)
                    }
                    if sessionsForDate.isEmpty && store.scheduledWorkouts(on: selectedDate).isEmpty {
                        Text("Rest day · no workout logged").font(.caption).foregroundStyle(colors.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .gesture(DragGesture(minimumDistance: 35).onEnded { value in
            if value.translation.width < -45 { changeMonth(1) }
            if value.translation.width > 45 { changeMonth(-1) }
        })
    }

    private func changeMonth(_ delta: Int) {
        if let date = Calendar.current.date(byAdding: .month, value: delta, to: first) { month = date }
    }
}

struct OlympiaHistoryView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: OlympiaTrainingSession?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.sessions.filter { !["preparing", "working", "resting", "paused"].contains($0.status) }) { session in
                    Button { selected = session } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.name).font(.headline)
                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(session.completedSets.count) sets").font(.caption)
                        }
                    }
                }.onDelete { indices in
                    let visible = store.sessions.filter { !["preparing", "working", "resting", "paused"].contains($0.status) }
                    indices.forEach { store.deleteSession(visible[$0]) }
                }
            }.navigationTitle("Workout history")
                .toolbar { Button("Done") { dismiss() } }
                .sheet(item: $selected) { OlympiaSessionDetailView(store: store, session: $0) }
        }
    }
}

struct OlympiaSessionDetailView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @EnvironmentObject private var productStore: ProductStore
    let session: OlympiaTrainingSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("olympia.units") private var units = "lb"
    @State private var confirmDelete = false

    private var names: [String] {
        var seen = Set<String>()
        return session.completedSets.map(\.exerciseName).filter { seen.insert($0).inserted }
    }
    private var heartOverview: SessionOverview? {
        guard let id = session.heartRateSessionID,
              let measurement = productStore.allSessions.first(where: { $0.id == id }) else { return nil }
        return ProductStore.makeOverview(measurement)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Date", value: session.startedAt.formatted(date: .complete, time: .omitted))
                    LabeledContent("Duration", value: "\(Int(session.duration / 60)) min")
                    LabeledContent("Total sets", value: "\(session.completedSets.count)")
                    if let average = session.averageHeartRate ?? heartOverview?.averageHeartRate.value {
                        LabeledContent("Average heart rate", value: "\(Int(average.rounded())) bpm")
                    }
                }
                ForEach(names, id: \.self) { name in
                    DisclosureGroup {
                        ForEach(session.completedSets.filter { $0.exerciseName == name }) { set in
                            HStack {
                                Text("Set \(set.setNumber)")
                                Spacer()
                                Text("\(set.reps.map(String.init) ?? "—") reps × \(set.weightPounds.map { String(format: "%.1f", units == "kg" ? $0 / 2.2046226218 : $0) } ?? "BW") \(units)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        HStack {
                            Text(name).font(.headline)
                            Spacer()
                            Text("\(session.completedSets.filter { $0.exerciseName == name }.count) sets")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { store.deleteExercise(name, from: session) }
                    }
                }
                Section {
                    Button("Delete entire workout", role: .destructive) { confirmDelete = true }
                }
            }.navigationTitle(session.name)
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Delete this workout and all its sets?", isPresented: $confirmDelete) {
                    Button("Delete workout", role: .destructive) { store.deleteSession(session); dismiss() }
                }
        }
    }
}

struct OlympiaWeightEntryView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("olympia.units") private var units = "lb"
    @State private var value = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Body weight (\(units))", text: $value).keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
            }.navigationTitle("Log body weight")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let number = Double(value) { store.logWeight(number, kilograms: units == "kg", at: date) }
                            dismiss()
                        }.disabled(Double(value) == nil)
                    }
                }
        }
    }
}
