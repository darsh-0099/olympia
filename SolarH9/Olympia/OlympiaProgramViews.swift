import SwiftUI

private let workoutColors = ["#63C7FF", "#FF7384", "#AD8CFF", "#73DD91", "#FFC56B"]

struct OlympiaProgramView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @ObservedObject var engine: OlympiaWorkoutEngine
    @Environment(\.olympiaColors) private var colors
    @State private var editingWorkout: OlympiaWorkoutTemplate?
    @State private var showNewWorkout = false
    @State private var showProgram = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("YOUR TRAINING PLAN").font(.caption2.bold()).tracking(1.5).foregroundStyle(colors.muted)
                            Text("Program").font(.system(size: 28, weight: .bold)).foregroundStyle(colors.text)
                        }
                        Spacer()
                        Button { showNewWorkout = true } label: {
                            Image(systemName: "plus").font(.headline).foregroundStyle(colors.text)
                                .frame(width: 44, height: 44).background(colors.secondarySurface, in: Circle())
                        }.buttonStyle(OlympiaPressStyle()).accessibilityLabel("Add workout")
                    }
                    OlympiaCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(store.activeProgram == nil ? "NO ACTIVE PROGRAM" : "ACTIVE PROGRAM")
                                .font(.caption2.bold()).tracking(1.5).foregroundStyle(colors.muted)
                            Text(store.activeProgram?.name ?? "Put your workouts on a schedule")
                                .font(.title3.bold()).foregroundStyle(colors.text)
                            Text(store.activeProgram.map { $0.scheduleType == "rotation" ? "Workout rotation · \($0.slots.count) workouts" : "Weekly schedule · \($0.slots.count) workout slots" }
                                 ?? "Create workouts, then combine them into the program you want to follow.")
                                .font(.caption).foregroundStyle(colors.muted)
                            if !store.workouts.isEmpty {
                                Button(store.activeProgram == nil ? "Set up program" : "Edit schedule") { showProgram = true }
                                    .font(.subheadline.bold()).foregroundStyle(colors.accent)
                            }
                        }
                    }
                    HStack {
                        Text("Workouts").font(.headline).foregroundStyle(colors.text)
                        Spacer()
                        Button("+ Add workout") { showNewWorkout = true }.font(.caption.bold())
                    }.padding(.top, 8)
                    if store.workouts.isEmpty {
                        OlympiaCard {
                            VStack(spacing: 10) {
                                Image(systemName: "dumbbell").font(.title).foregroundStyle(colors.accent)
                                Text("Create your first workout").font(.headline)
                                Text("Add exercises, sets, and rest times. Scheduling happens in Program.")
                                    .font(.caption).foregroundStyle(colors.muted).multilineTextAlignment(.center)
                                Button("Create workout") { showNewWorkout = true }
                                    .font(.subheadline.bold()).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .background(colors.accent, in: Capsule())
                                    .buttonStyle(OlympiaPressStyle())
                            }.frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                    } else {
                        ForEach(store.workouts) { workout in
                            OlympiaSwipeToDeleteRow {
                                store.deleteWorkout(workout)
                            } content: {
                                Button { editingWorkout = workout } label: {
                                    OlympiaCard {
                                        HStack(spacing: 12) {
                                            Circle().fill(Color(olympiaHex: workout.colorHex)).frame(width: 9, height: 9)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(workout.name).font(.headline).foregroundStyle(Color(olympiaHex: workout.colorHex))
                                                Text(workout.exercises.map(\.name).joined(separator: " · "))
                                                    .font(.caption).foregroundStyle(colors.muted).lineLimit(2)
                                                Text("\(workout.exercises.count) exercises · \(workout.exercises.reduce(0) { $0 + $1.sets }) sets")
                                                    .font(.caption2).foregroundStyle(colors.muted)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(colors.muted)
                                        }
                                    }
                                }.buttonStyle(OlympiaPressStyle())
                            }
                        }
                    }
                }.padding(20)
            }.scrollIndicators(.hidden).background(colors.background).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showNewWorkout) { OlympiaWorkoutEditor(store: store, workout: nil) }
            .sheet(item: $editingWorkout) { OlympiaWorkoutEditor(store: store, workout: $0) }
            .sheet(isPresented: $showProgram) { OlympiaProgramEditor(store: store) }
        }
    }
}

private struct OlympiaSwipeToDeleteRow<Content: View>: View {
    let delete: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var rowWidth: CGFloat = 320

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .frame(width: 88, height: 100)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            content
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            offset = min(0, max(-rowWidth, value.translation.width))
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if value.translation.width < -max(180, rowWidth * 0.8) {
                                delete()
                            } else {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                    offset = value.translation.width < -44 ? -88 : 0
                                }
                            }
                        }
                )
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { rowWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in rowWidth = width }
            }
        }
        .accessibilityAction(named: "Delete workout", delete)
    }
}

struct OlympiaWorkoutEditor: View {
    @ObservedObject var store: OlympiaTrainingStore
    let workout: OlympiaWorkoutTemplate?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.olympiaColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var colorHex = workoutColors[0]
    @State private var exercises: [OlympiaExercise] = []
    @State private var showHistory = false
    @State private var showDelete = false
    @State private var showValidation = false
    @State private var validationMessage = ""
    @State private var pendingHistoryWorkout: OlympiaWorkoutSuggestion?
    @State private var weightInputs: [UUID: String] = [:]
    @FocusState private var textFieldFocused: Bool
    @AppStorage("olympia.units") private var units = "lb"

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        exercises.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } &&
        !hasInvalidTargetWeight
    }

    private var hasInvalidTargetWeight: Bool {
        exercises.contains { exercise in
            guard let text = weightInputs[exercise.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return false }
            guard let value = Double(text) else { return true }
            return !value.isFinite || !(0...2000).contains(value)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    TextField("Workout name", text: $name)
                        .font(.title2.bold()).foregroundStyle(Color(olympiaHex: colorHex))
                        .textInputAutocapitalization(.words).padding(.vertical, 8)
                        .focused($textFieldFocused)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            Label("Color", systemImage: "paintpalette.fill").font(.subheadline.bold())
                            ForEach(workoutColors, id: \.self) { hex in
                                Button { colorHex = hex } label: {
                                    Circle().fill(Color(olympiaHex: hex)).frame(width: 32, height: 32)
                                        .overlay(Circle().stroke(.white, lineWidth: colorHex == hex ? 2 : 0).padding(3))
                                }.buttonStyle(OlympiaPressStyle()).accessibilityLabel("Select workout color \(hex)")
                                    .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                            }
                        }
                    }.scrollIndicators(.hidden)
                }.listRowBackground(colors.surface)
                Section {
                    ForEach($exercises) { $exercise in
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Exercise name", text: $exercise.name)
                                .font(.subheadline.bold()).textInputAutocapitalization(.words)
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .background(colors.secondarySurface, in: RoundedRectangle(cornerRadius: 12))
                                .focused($textFieldFocused)
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("SETS").font(.caption2.bold()).foregroundStyle(colors.muted)
                                    HStack(spacing: 0) {
                                        Button { exercise.sets = max(1, exercise.sets - 1) } label: {
                                            Image(systemName: "minus").frame(width: 42, height: 42)
                                        }.disabled(exercise.sets <= 1)
                                        Text("\(exercise.sets)").font(.subheadline.bold())
                                            .monospacedDigit().frame(minWidth: 25)
                                        Button { exercise.sets = min(12, exercise.sets + 1) } label: {
                                            Image(systemName: "plus").frame(width: 42, height: 42)
                                        }.disabled(exercise.sets >= 12)
                                    }
                                    .background(colors.secondarySurface, in: Capsule())
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("REST").font(.caption2.bold()).foregroundStyle(colors.muted)
                                    Menu {
                                        ForEach([0, 30, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { seconds in
                                            Button(seconds == 0 ? "No rest" : "\(seconds)s") { exercise.restSeconds = seconds }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(exercise.restSeconds == 0 ? "None" : "\(exercise.restSeconds)s")
                                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                                        }
                                        .font(.subheadline.bold()).foregroundStyle(colors.text)
                                        .frame(minWidth: 92, minHeight: 42)
                                        .background(colors.secondarySurface, in: Capsule())
                                    }
                                }
                            }
                            HStack(spacing: 10) {
                                Text("Target weight").font(.caption).foregroundStyle(colors.muted)
                                Spacer(minLength: 0)
                                TextField("Optional", text: targetWeightBinding(for: $exercise))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($textFieldFocused)
                                    .frame(maxWidth: 96)
                                Text(units).font(.caption).foregroundStyle(colors.muted)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(colors.secondarySurface, in: RoundedRectangle(cornerRadius: 12))
                        }.padding(.vertical, 8).listRowBackground(colors.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Delete", role: .destructive) {
                                    exercises.removeAll { $0.id == exercise.id }
                                }
                            }
                    }.onMove { exercises.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { exercises.remove(atOffsets: $0) }
                    Button("Add exercise") { exercises.append(OlympiaExercise(name: "", sets: 3, restSeconds: 90)) }
                    Button("From workout history") { showHistory = true }
                } header: { Text("Exercises · drag to reorder") }
                    .listRowBackground(colors.surface)
                if workout != nil {
                    Section { Button("Delete workout", role: .destructive) { showDelete = true } }
                        .listRowBackground(colors.surface)
                }
            }
            .scrollContentBackground(.hidden).scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively).background(colors.background)
            .foregroundStyle(colors.text)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(workout == nil ? "Create workout" : "Save workout") {
                    textFieldFocused = false
                    guard canSave else {
                        validationMessage = hasInvalidTargetWeight
                            ? "Enter a target weight from 0 to 2000 \(units), or leave it blank."
                            : "Enter a workout name and at least one exercise name."
                        showValidation = true
                        return
                    }
                    store.upsertWorkout(id: workout?.id, name: name, colorHex: colorHex, exercises: exercises)
                    dismiss()
                }.font(.subheadline.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
                    .background(colors.accent.opacity(canSave ? 1 : 0.35), in: Capsule())
                    .contentShape(Capsule()).buttonStyle(OlympiaPressStyle())
                    .padding(.horizontal, 20).padding(.vertical, 12).background(colors.background)
            }
            .navigationTitle(workout == nil ? "New workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { EditButton() }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { textFieldFocused = false }
                }
            }
            .onAppear {
                guard let workout else { return }
                name = workout.name; colorHex = workout.colorHex; exercises = workout.exercises
            }
            .onChange(of: units) { _, _ in weightInputs.removeAll() }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    List {
                        let suggestions = store.historyWorkoutSuggestions()
                        if !suggestions.isEmpty {
                            Section("Quick add a previous workout") {
                                ForEach(suggestions, id: \.id) { suggestion in
                                    Button {
                                        if workout != nil ||
                                            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                            !exercises.isEmpty {
                                            pendingHistoryWorkout = suggestion
                                        } else {
                                            useHistoryWorkout(suggestion)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(colors.accent)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(suggestion.name).foregroundStyle(colors.text)
                                                Text("\(suggestion.exercises.map(\.name).joined(separator: " · ")) · \(suggestion.lastPerformedAt, style: .date)")
                                                    .font(.caption).foregroundStyle(colors.muted)
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill").foregroundStyle(colors.accent)
                                        }
                                        .frame(minHeight: 48).contentShape(Rectangle())
                                    }.buttonStyle(.plain).listRowBackground(colors.surface)
                                }
                            }
                        }
                        Section("Individual exercises") {
                            ForEach(store.historyExercises(), id: \.self) { exercise in
                                let selected = exercises.contains { olympiaExerciseKey($0.name) == olympiaExerciseKey(exercise) }
                                Button {
                                    if selected {
                                        exercises.removeAll { olympiaExerciseKey($0.name) == olympiaExerciseKey(exercise) }
                                    } else {
                                        let recentCount = store.sessions.first { session in
                                            session.completedSets.contains { olympiaExerciseKey($0.exerciseName) == olympiaExerciseKey(exercise) }
                                        }?.completedSets.filter { olympiaExerciseKey($0.exerciseName) == olympiaExerciseKey(exercise) }.count ?? 3
                                        exercises.append(OlympiaExercise(name: exercise, sets: max(1, min(12, recentCount)), restSeconds: 90))
                                    }
                                } label: {
                                    HStack {
                                        Text(exercise).foregroundStyle(colors.text)
                                        Spacer()
                                        if let prior = store.previousSet(exercise: exercise, setNumber: 1) {
                                            Text("\(prior.displayReps) reps · \(Int(units == "kg" ? (prior.weightPounds ?? 0) / 2.2046226218 : (prior.weightPounds ?? 0))) \(units)")
                                                .font(.caption).foregroundStyle(colors.muted)
                                        }
                                        Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundStyle(selected ? colors.accent : colors.muted)
                                    }
                                    .frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("\(exercise), \(selected ? "selected" : "not selected")")
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .listRowBackground(colors.surface)
                            }
                        }
                    }.scrollContentBackground(.hidden).scrollIndicators(.hidden)
                        .background(colors.background).navigationTitle("Workout history")
                        .toolbar { Button("Done") { showHistory = false } }
                        .confirmationDialog("Replace the current workout?",
                                            isPresented: Binding(
                                                get: { pendingHistoryWorkout != nil },
                                                set: { if !$0 { pendingHistoryWorkout = nil } })) {
                            Button("Replace with logged workout", role: .destructive) {
                                if let pendingHistoryWorkout { useHistoryWorkout(pendingHistoryWorkout) }
                            }
                            Button("Keep editing", role: .cancel) { pendingHistoryWorkout = nil }
                        } message: {
                            Text("This will replace the current name and exercise list.")
                        }
                }
            }
            .confirmationDialog("Delete this workout? History will be kept.", isPresented: $showDelete) {
                Button("Delete workout", role: .destructive) {
                    if let workout { store.deleteWorkout(workout) }; dismiss()
                }
            }
            .alert("Can't save workout", isPresented: $showValidation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(validationMessage)
            }
        }.tint(colors.accent).presentationCornerRadius(28)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: colorHex)
    }

    private func useHistoryWorkout(_ suggestion: OlympiaWorkoutSuggestion) {
        name = suggestion.name
        exercises = suggestion.exercises
        weightInputs.removeAll()
        pendingHistoryWorkout = nil
        showHistory = false
    }

    private func targetWeightBinding(for exercise: Binding<OlympiaExercise>) -> Binding<String> {
        Binding(
            get: {
                let item = exercise.wrappedValue
                return weightInputs[item.id] ??
                    item.targetWeightPounds.map { String(format: "%g", units == "kg" ? $0 / 2.2046226218 : $0) } ?? ""
            },
            set: { text in
                var updated = exercise.wrappedValue
                weightInputs[updated.id] = text
                let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
                updated.targetWeightPounds = parsed.flatMap { value in
                    value.isFinite && (0...2000).contains(value)
                        ? (units == "kg" ? value * 2.2046226218 : value) : nil
                }
                exercise.wrappedValue = updated
            }
        )
    }
}

struct OlympiaProgramEditor: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.olympiaColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = "My Program"
    @State private var scheduleType = "weekly"
    @State private var restDays = 0
    @State private var slots: [OlympiaProgramSlot] = []
    @State private var showValidation = false
    @FocusState private var nameFocused: Bool
    private let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !slots.isEmpty &&
        (scheduleType != "weekly" || !slots.allSatisfy { $0.weekdays.isEmpty })
    }
    private var rotationDescription: String {
        slots.enumerated().map { entry in
            let name = store.workouts.first(where: { $0.id == entry.element.workoutID })?.name ?? "Workout"
            return "\(entry.offset + 1). \(name)"
        }.joined(separator: "  ·  ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Program") {
                    TextField("Program name", text: $name)
                        .font(.title2.bold()).padding(.vertical, 8)
                        .focused($nameFocused)
                    Picker("Schedule", selection: $scheduleType) {
                        Text("Weekly").tag("weekly")
                        Text("Rotation").tag("rotation")
                    }.pickerStyle(.segmented)
                    if scheduleType == "rotation" {
                        Stepper("Rest days after rotation: \(restDays)", value: $restDays, in: 0...7)
                        Text("After each workout in order, take your chosen number of rest days, then repeat.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.listRowBackground(colors.surface)
                Section("Workouts") {
                    ForEach(store.workouts) { workout in
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { slots.contains { $0.workoutID == workout.id } },
                                set: { enabled in
                                    if enabled {
                                        slots.append(OlympiaProgramSlot(workoutID: workout.id,
                                                                        weekdays: [], colorHex: workout.colorHex))
                                    } else { slots.removeAll { $0.workoutID == workout.id } }
                                })) {
                                    Text(workout.name).font(.subheadline.bold())
                                        .foregroundStyle(Color(olympiaHex: workout.colorHex))
                                }
                            if scheduleType == "weekly", let index = slots.firstIndex(where: { $0.workoutID == workout.id }) {
                                HStack(spacing: 5) {
                                    ForEach(1...7, id: \.self) { weekday in
                                        let selected = slots[index].weekdays.contains(weekday)
                                        Button(days[weekday - 1]) {
                                            if selected { slots[index].weekdays.removeAll { $0 == weekday } }
                                            else { slots[index].weekdays.append(weekday) }
                                        }.font(.caption2.bold()).frame(maxWidth: .infinity).frame(minHeight: 44)
                                            .background(selected ? Color(olympiaHex: workout.colorHex) : colors.secondarySurface,
                                                        in: Capsule())
                                            .foregroundStyle(selected ? Color.black : colors.muted)
                                            .buttonStyle(OlympiaPressStyle())
                                            .accessibilityAddTraits(selected ? .isSelected : [])
                                    }
                                }
                            }
                        }.padding(.vertical, 3)
                    }
                    if scheduleType == "rotation", !slots.isEmpty {
                        Text("Rotation order: \(rotationDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.listRowBackground(colors.surface)
            }.scrollContentBackground(.hidden).scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively).background(colors.background)
                .foregroundStyle(colors.text)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button("Save schedule") {
                        nameFocused = false
                        guard canSave else { showValidation = true; return }
                        store.upsertProgram(id: store.activeProgram?.id, name: name,
                                            scheduleType: scheduleType, rotationRestDays: restDays, slots: slots)
                        dismiss()
                    }.font(.subheadline.bold()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(colors.accent.opacity(canSave ? 1 : 0.35), in: Capsule())
                        .contentShape(Capsule()).buttonStyle(OlympiaPressStyle())
                        .padding(.horizontal, 20).padding(.vertical, 12).background(colors.background)
                }
                .navigationTitle("Schedule").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { nameFocused = false }
                    }
                }
                .onAppear {
                    if let program = store.activeProgram {
                        name = program.name; scheduleType = program.scheduleType
                        restDays = program.rotationRestDays; slots = program.slots
                    }
                }
                .alert("Schedule isn't ready", isPresented: $showValidation) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(name.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Enter a program name."
                         : slots.isEmpty
                            ? "Choose at least one workout."
                            : "Choose at least one day for a workout, or switch to Rotation.")
                }
        }.tint(colors.accent).presentationCornerRadius(28)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: scheduleType)
    }
}
