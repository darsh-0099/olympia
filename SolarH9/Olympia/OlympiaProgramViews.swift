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
                            .swipeActions { Button("Delete", role: .destructive) { store.deleteWorkout(workout) } }
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        exercises.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout") {
                    TextField("Workout name", text: $name)
                        .font(.title2.bold()).foregroundStyle(Color(olympiaHex: colorHex))
                        .textInputAutocapitalization(.words).padding(.vertical, 8)
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
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Exercise name", text: $exercise.name)
                                .font(.subheadline.bold()).textInputAutocapitalization(.words)
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .background(colors.secondarySurface, in: Capsule())
                            HStack {
                                Stepper("\(exercise.sets) sets", value: $exercise.sets, in: 1...12)
                                Spacer()
                                Picker("Rest", selection: $exercise.restSeconds) {
                                    ForEach([0, 30, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { seconds in
                                        Text(seconds == 0 ? "No rest" : "\(seconds)s").tag(seconds)
                                    }
                                }.fixedSize().tint(colors.text)
                            }.font(.caption)
                        }.padding(.vertical, 6).listRowBackground(colors.surface)
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
                    store.upsertWorkout(id: workout?.id, name: name, colorHex: colorHex, exercises: exercises)
                    dismiss()
                }.font(.subheadline.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 17)
                    .background(colors.accent.opacity(canSave ? 1 : 0.35), in: Capsule())
                    .buttonStyle(OlympiaPressStyle()).disabled(!canSave)
                    .padding(.horizontal, 20).padding(.vertical, 12).background(colors.background)
            }
            .navigationTitle(workout == nil ? "New workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { EditButton() }
            }
            .onAppear {
                guard let workout else { return }
                name = workout.name; colorHex = workout.colorHex; exercises = workout.exercises
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    List(store.historyExercises(), id: \.self) { exercise in
                        Button {
                            let recentCount = store.sessions.first { session in
                                session.completedSets.contains { $0.exerciseName == exercise }
                            }?.completedSets.filter { $0.exerciseName == exercise }.count ?? 3
                            exercises.append(OlympiaExercise(name: exercise, sets: max(1, min(12, recentCount)), restSeconds: 90))
                        } label: {
                            HStack {
                                Text(exercise)
                                Spacer()
                                if let prior = store.previousSet(exercise: exercise, setNumber: 1) {
                                    Text("\(prior.reps ?? 0) reps · \(Int(prior.weightPounds ?? 0)) lb").font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "plus")
                            }
                        }.listRowBackground(colors.surface)
                    }.scrollContentBackground(.hidden).scrollIndicators(.hidden)
                        .background(colors.background).navigationTitle("Previous exercises")
                        .toolbar { Button("Done") { showHistory = false } }
                }
            }
            .confirmationDialog("Delete this workout? History will be kept.", isPresented: $showDelete) {
                Button("Delete workout", role: .destructive) {
                    if let workout { store.deleteWorkout(workout) }; dismiss()
                }
            }
        }.tint(colors.accent).presentationCornerRadius(28)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: colorHex)
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
                        store.upsertProgram(id: store.activeProgram?.id, name: name,
                                            scheduleType: scheduleType, rotationRestDays: restDays, slots: slots)
                        dismiss()
                    }.font(.subheadline.bold()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(colors.accent.opacity(canSave ? 1 : 0.35), in: Capsule())
                        .buttonStyle(OlympiaPressStyle()).disabled(!canSave)
                        .padding(.horizontal, 20).padding(.vertical, 12).background(colors.background)
                }
                .navigationTitle("Schedule").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .onAppear {
                    if let program = store.activeProgram {
                        name = program.name; scheduleType = program.scheduleType
                        restDays = program.rotationRestDays; slots = program.slots
                    }
                }
        }.tint(colors.accent).presentationCornerRadius(28)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: scheduleType)
    }
}
