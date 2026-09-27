import SwiftUI

struct OlympiaActiveWorkoutView: View {
    private enum EntryField: Hashable { case weight, reps }
    @ObservedObject var store: OlympiaTrainingStore
    @ObservedObject var engine: OlympiaWorkoutEngine
    @EnvironmentObject private var sensor: SensorCoordinator
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.olympiaColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var entryFocused: EntryField?
    @AppStorage("olympia.units") private var units = "lb"
    @State private var weight = ""
    @State private var reps = ""
    @State private var showEnd = false
    @State private var sensorSessionStarted = false
    @State private var sensorStartTask: Task<Void, Never>?
    @State private var isEnding = false
    @State private var showDevicePicker = false

    private var workoutColor: Color {
        guard let workout = store.workouts.first(where: { $0.id == engine.session?.workoutID }) else {
            return colors.accent
        }
        return Color(olympiaHex: workout.colorHex)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if engine.phase == "preparing" { preparation }
                    else if engine.phase == "resting" { rest }
                    else if engine.phase == "paused" { paused }
                    else { working }
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 40), alignment: .top)
                .padding(20)
            }
            .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .background(colors.background.ignoresSafeArea())
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
        .foregroundStyle(colors.text)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: engine.phase)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { entryFocused = nil }
            }
        }
        .onChange(of: engine.phase) { _, phase in
            if phase != "working" { entryFocused = nil }
            if phase == "working" { beginSensorSessionIfReady() }
            if phase == "working" { prefill() }
        }
        .onChange(of: sensor.currentHeartRate) { _, _ in beginSensorSessionIfReady() }
        .onAppear {
            beginSensorSessionIfReady()
            prefill()
        }
        .sheet(isPresented: $showDevicePicker) { DevicePickerView() }
        .disabled(isEnding)
        .confirmationDialog("End workout?", isPresented: $showEnd) {
            Button("Finish and save", role: .destructive) { endWorkout(cancel: false) }
            Button("Discard workout", role: .destructive) { endWorkout(cancel: true) }
        } message: { Text("Completed sets are saved if you finish.") }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                Text(engine.session?.name ?? "Workout")
                    .font(.headline).foregroundStyle(workoutColor).lineLimit(2)
                Spacer()
                Label(String(format: "%02d:%02d", engine.elapsedSeconds / 60, engine.elapsedSeconds % 60), systemImage: "clock")
                    .font(.subheadline.bold()).monospacedDigit().accessibilityLabel("Total workout time")
                    .accessibilityValue("\(engine.elapsedSeconds / 60) minutes, \(engine.elapsedSeconds % 60) seconds")
            }
            HStack {
                Button("End workout") { showEnd = true }
                    .font(.caption.bold()).foregroundStyle(colors.muted)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(colors.secondarySurface, in: Capsule()).buttonStyle(OlympiaPressStyle())
                Spacer()
                Button {
                    if engine.phase == "paused" { engine.resume(); pauseOrResumeHeartRate() }
                    else if engine.phase == "working" || engine.phase == "resting" {
                        engine.pause(); pauseOrResumeHeartRate()
                    }
                } label: {
                    Image(systemName: engine.phase == "paused" ? "play.fill" : "pause.fill")
                        .font(.subheadline.bold()).frame(width: 44, height: 44)
                        .background(colors.secondarySurface, in: Circle())
                }.buttonStyle(OlympiaPressStyle())
                    .accessibilityLabel(engine.phase == "paused" ? "Resume workout" : "Pause workout")
                    .disabled(engine.phase == "preparing")
            }
            if let bpm = sensor.currentHeartRate, sensor.selectedSource != .simulator {
                HStack(spacing: 7) {
                    Label("\(bpm) bpm", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                    if let zone = sensor.currentZone(for: bpm) {
                        Text("ZONE \(zone)").foregroundStyle(colors.accent)
                    }
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(colors.surface, in: Capsule())
            } else {
                if sensor.selectedSource == .simulator {
                    Text("Simulated sensor mode").font(.caption).foregroundStyle(colors.muted)
                } else {
                    Button("Connect heart-rate sensor") { showDevicePicker = true; sensor.sensor.scan() }
                        .font(.caption).foregroundStyle(colors.accent)
                }
            }
        }.foregroundStyle(colors.text).frame(maxWidth: .infinity)
    }

    private var preparation: some View {
        VStack(spacing: 20) {
            countdown(seconds: engine.secondsRemaining, total: 120)
            Text("Set up before the clock starts").font(.title3.bold())
            Text("Your workout timer begins when prep ends. Previous-session weights are below.")
                .font(.subheadline).foregroundStyle(colors.muted).multilineTextAlignment(.center)
            ForEach(engine.exercises.indices, id: \.self) { index in
                let exercise = engine.exercises[index]
                OlympiaCard {
                    HStack {
                        Text("\(index + 1)").foregroundStyle(colors.accent)
                        Text(exercise.name).lineLimit(2)
                        Spacer()
                        if let set = store.previousSet(exercise: exercise.name, setNumber: 1),
                           let pounds = set.weightPounds {
                            Text(String(format: "%.0f %@", units == "kg" ? pounds / 2.2046226218 : pounds, units))
                                .font(.caption.bold()).foregroundStyle(colors.accent)
                        }
                    }
                }
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Exercise \((engine.session?.exerciseIndex ?? 0) + 1) of \(engine.exercises.count)")
                Spacer()
                Text("\(Int(engine.progress * 100))%")
            }.font(.caption).foregroundStyle(colors.muted)
            ProgressView(value: engine.progress).tint(colors.accent)
            OlympiaCard {
                VStack(alignment: .leading, spacing: 15) {
                    Text(engine.currentExercise?.name ?? "Workout complete")
                        .font(.title2.bold()).foregroundStyle(workoutColor)
                    HStack {
                        Label("\(engine.currentExercise?.restSeconds ?? 90)s rest", systemImage: "timer")
                        Spacer()
                        Text("Set \(engine.session?.setNumber ?? 1) of \(engine.currentExercise?.sets ?? 1)")
                    }.font(.caption.bold()).foregroundStyle(colors.muted)
                    if let exercise = engine.currentExercise,
                       let previous = store.previousSet(exercise: exercise.name,
                                                        setNumber: engine.session?.setNumber ?? 1) {
                        Text("Previous: \(previous.weightPounds.map { String(format: "%.0f", units == "kg" ? $0 / 2.2046226218 : $0) } ?? "BW") \(units) × \(previous.reps.map(String.init) ?? "—") reps")
                            .font(.caption.bold()).foregroundStyle(colors.accent)
                    }
                    HStack(spacing: 10) {
                        VStack(spacing: 8) {
                            Text("Reps").font(.caption2).foregroundStyle(colors.muted)
                            TextField("—", text: $reps).keyboardType(.numberPad)
                                .focused($entryFocused, equals: .reps).multilineTextAlignment(.center)
                                .padding(.vertical, 14).background(colors.secondarySurface, in: Capsule())
                                .accessibilityLabel("Completed repetitions")
                        }
                        VStack(spacing: 8) {
                            Text("Weight (\(units))").font(.caption2).foregroundStyle(colors.muted)
                            TextField("—", text: $weight).keyboardType(.decimalPad)
                                .focused($entryFocused, equals: .weight).multilineTextAlignment(.center)
                                .padding(.vertical, 14).background(colors.secondarySurface, in: Capsule())
                                .accessibilityLabel("Completed weight in \(units)")
                        }
                    }
                    Text("Enter what you completed, then rest begins.")
                        .font(.caption2).foregroundStyle(colors.muted)
                }
            }
        }
    }

    private var rest: some View {
        VStack(spacing: 23) {
            countdown(seconds: engine.secondsRemaining, total: max(1, engine.session?.completedSets.last?.restSeconds ?? 90))
            Text("Recovery").font(.title.bold())
            Text("Next: \(engine.currentExercise?.name ?? "Exercise") · Set \(engine.session?.setNumber ?? 1)")
                .font(.subheadline).foregroundStyle(colors.muted)
            HStack {
                Button("−15 sec") { engine.adjustRest(by: -15) }
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(colors.secondarySurface, in: Capsule())
                Button("+15 sec") { engine.adjustRest(by: 15) }
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(colors.secondarySurface, in: Capsule())
            }
            .font(.subheadline.bold()).buttonStyle(OlympiaPressStyle())
        }
    }

    private var paused: some View {
        VStack(spacing: 20) {
            Image(systemName: "pause.circle.fill").font(.system(size: 90)).foregroundStyle(colors.accent)
            Text("Workout paused").font(.title.bold())
            Text("Your workout and rest clocks are paused.").foregroundStyle(colors.muted)
        }.frame(maxWidth: .infinity).padding(.top, 45)
    }

    private func countdown(seconds: Int, total: Int) -> some View {
        ZStack {
            Circle().stroke(colors.border, lineWidth: 6)
            Circle().trim(from: 0, to: CGFloat(min(1, Double(seconds) / Double(max(1, total)))))
                .stroke(colors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: seconds)
            VStack(spacing: 0) {
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Text(engine.phase == "preparing" ? "GET READY" : "REST TIMER")
                    .font(.caption2).tracking(1.5).foregroundStyle(colors.muted)
            }
        }.frame(width: 170, height: 170).padding(.top, 20)
    }

    private var actionFooter: some View {
        Button {
            entryFocused = nil
            switch engine.phase {
            case "preparing": engine.beginNow()
            case "resting": engine.skipRest()
            case "paused": engine.resume(); pauseOrResumeHeartRate()
            default:
                let draft = engine.session
                let enteredWeight = Double(weight).map { units == "kg" ? $0 * 2.2046226218 : $0 }
                engine.completeSet(weightPounds: enteredWeight, reps: Int(reps))
                prefill()
                if !engine.isActive { Task {
                    await sensorStartTask?.value
                    await finishHeartRate(for: draft, cancel: false)
                } }
            }
        } label: {
            Text(engine.phase == "preparing" ? "Start now" :
                    engine.phase == "resting" ? "Skip rest" :
                    engine.phase == "paused" ? "Resume workout" : "Complete set \(engine.session?.setNumber ?? 1)")
                .font(.subheadline.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(colors.accent, in: Capsule())
        }.buttonStyle(OlympiaPressStyle())
            .disabled(engine.phase == "working" && Double(weight) == nil && Int(reps) == nil)
            .opacity(engine.phase == "working" && Double(weight) == nil && Int(reps) == nil ? 0.4 : 1)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            .padding(.horizontal, 20).padding(.vertical, 12).background(colors.background)
    }

    private func prefill() {
        guard let exercise = engine.currentExercise else { return }
        let previous = store.previousSet(exercise: exercise.name, setNumber: engine.session?.setNumber ?? 1)
        weight = previous?.weightPounds.map { String(format: "%.1f", units == "kg" ? $0 / 2.2046226218 : $0) } ?? ""
        reps = previous?.reps.map(String.init) ?? ""
    }

    private func endWorkout(cancel: Bool) {
        guard !isEnding else { return }
        isEnding = true
        let draft = engine.session
        Task {
            // Starting a recording checkpoints asynchronously. Wait for its ID
            // before deleting the training draft or stopping the recording.
            await sensorStartTask?.value
            let heartRateSessionID = draft?.heartRateSessionID
            if cancel { engine.cancel() } else { engine.finish() }
            await finishHeartRate(for: cancel ? nil : draft, cancel: cancel,
                                  recordingID: heartRateSessionID)
        }
    }

    private func pauseOrResumeHeartRate() {
        guard let id = engine.session?.heartRateSessionID else { return }
        Task { await sensor.pauseOrResume(id: id) }
    }

    private func finishHeartRate(for draft: OlympiaTrainingSession?, cancel: Bool,
                                 recordingID: UUID? = nil) async {
        guard let id = recordingID ?? draft?.heartRateSessionID else { return }
        let ended = await sensor.endWorkout(id: id)
        if cancel {
            guard ended else {
                store.errorMessage = "Workout discarded. The heart-rate recording still needs to finish saving before it can be deleted."
                return
            }
            if !(await productStore.deleteSession(id: id)) {
                store.errorMessage = "Workout discarded, but its heart-rate recording could not be deleted."
            }
        } else {
            await productStore.refresh()
            attachHeartRate(to: draft)
        }
    }

    private func beginSensorSessionIfReady() {
        guard engine.phase == "working", !isEnding, !sensorSessionStarted,
              sensor.sourceIsReady, let session = engine.session else { return }
        // A restored workout already owns its saved ID. Never adopt an
        // unrelated active recording or overwrite the restored association.
        guard session.heartRateSessionID == nil, !sensor.hasActiveRecording else { return }
        sensorSessionStarted = true
        sensorStartTask = Task {
            if let id = await sensor.startWorkout() {
                session.heartRateSessionID = id
                store.persistSession(session)
            }
        }
    }

    private func attachHeartRate(to session: OlympiaTrainingSession?) {
        guard let session, let id = session.heartRateSessionID,
              let measurement = productStore.allSessions.first(where: { $0.id == id }),
              let overview = ProductStore.makeOverview(measurement),
              let average = overview.averageHeartRate.value else { return }
        session.averageHeartRate = average
        store.persistSession(session)
    }
}
