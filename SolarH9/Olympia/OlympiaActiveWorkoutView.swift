import SwiftUI

struct OlympiaActiveWorkoutView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @ObservedObject var engine: OlympiaWorkoutEngine
    @EnvironmentObject private var sensor: SensorCoordinator
    @EnvironmentObject private var productStore: ProductStore
    @Environment(\.olympiaColors) private var colors
    @AppStorage("olympia.units") private var units = "lb"
    @State private var weight = ""
    @State private var reps = ""
    @State private var showEnd = false
    @State private var sensorSessionStarted = false
    @State private var showDevicePicker = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 23) {
                    header
                    if engine.phase == "preparing" { preparation }
                    else if engine.phase == "resting" { rest }
                    else if engine.phase == "paused" { paused }
                    else { working }
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .padding(20)
            }
            .background(colors.background.ignoresSafeArea())
        }
        .onChange(of: engine.phase) { _, phase in
            if phase == "working" { beginSensorSessionIfReady() }
            if phase == "working" { prefill() }
        }
        .onChange(of: sensor.currentHeartRate) { _, _ in beginSensorSessionIfReady() }
        .onAppear {
            beginSensorSessionIfReady()
            prefill()
        }
        .sheet(isPresented: $showDevicePicker) { DevicePickerView() }
        .confirmationDialog("End workout?", isPresented: $showEnd) {
            Button("Finish and save", role: .destructive) { endWorkout(cancel: false) }
            Button("Discard workout", role: .destructive) { endWorkout(cancel: true) }
        } message: { Text("Completed sets are saved if you finish.") }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("End") { showEnd = true }.buttonStyle(.bordered)
                Spacer()
                Text(engine.session?.name.uppercased() ?? "WORKOUT")
                    .font(.caption2.bold()).tracking(1.5).lineLimit(1)
                Spacer()
                Button {
                    if engine.phase == "paused" { engine.resume(); Task { await sensor.pauseOrResume() } }
                    else if engine.phase == "working" || engine.phase == "resting" {
                        engine.pause(); Task { await sensor.pauseOrResume() }
                    }
                } label: {
                    Image(systemName: engine.phase == "paused" ? "play.fill" : "pause.fill")
                }.buttonStyle(.bordered)
                    .disabled(engine.phase == "preparing")
            }
            Text(String(format: "%02d:%02d", engine.elapsedSeconds / 60, engine.elapsedSeconds % 60))
                .font(.system(size: 62, weight: .bold, design: .rounded)).monospacedDigit()
            Text("TOTAL TIME").font(.caption2.bold()).tracking(2).foregroundStyle(colors.muted)
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
            Button("Start now") { engine.beginNow() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
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
                    Text("CURRENT EXERCISE").font(.caption2.bold()).tracking(1.5).foregroundStyle(colors.muted)
                    Text(engine.currentExercise?.name ?? "Workout complete")
                        .font(.title2.bold()).foregroundStyle(colors.text)
                    Text("Set \(engine.session?.setNumber ?? 1) of \(engine.currentExercise?.sets ?? 1)")
                        .font(.subheadline).foregroundStyle(colors.accent)
                    if let exercise = engine.currentExercise,
                       let previous = store.previousSet(exercise: exercise.name,
                                                        setNumber: engine.session?.setNumber ?? 1) {
                        Text("Previous: \(previous.weightPounds.map { String(format: "%.0f", units == "kg" ? $0 / 2.2046226218 : $0) } ?? "BW") \(units) × \(previous.reps.map(String.init) ?? "—") reps")
                            .font(.caption.bold()).foregroundStyle(colors.accent)
                    }
                    HStack {
                        TextField("Weight (\(units))", text: $weight).keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        TextField("Reps", text: $reps).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Enter what you completed, then rest begins.")
                        .font(.caption2).foregroundStyle(colors.muted)
                }
            }
            Button("Complete set \(engine.session?.setNumber ?? 1)") {
                let draft = engine.session
                let enteredWeight = Double(weight).map { units == "kg" ? $0 * 2.2046226218 : $0 }
                engine.completeSet(weightPounds: enteredWeight, reps: Int(reps))
                prefill()
                if !engine.isActive { Task {
                    await sensor.endWorkout(); await productStore.refresh(); attachHeartRate(to: draft)
                } }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(Double(weight) == nil && Int(reps) == nil)
        }
    }

    private var rest: some View {
        VStack(spacing: 23) {
            countdown(seconds: engine.secondsRemaining, total: max(1, engine.session?.completedSets.last?.restSeconds ?? 90))
            Text("Recovery").font(.title.bold())
            Text("Next: \(engine.currentExercise?.name ?? "Exercise") · Set \(engine.session?.setNumber ?? 1)")
                .font(.subheadline).foregroundStyle(colors.muted)
            HStack {
                Button("−15 sec") { engine.adjustRest(by: -15) }.buttonStyle(.bordered)
                Button("+15 sec") { engine.adjustRest(by: 15) }.buttonStyle(.bordered)
            }
            Button("Skip rest") { engine.skipRest() }.buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    private var paused: some View {
        VStack(spacing: 20) {
            Image(systemName: "pause.circle.fill").font(.system(size: 90)).foregroundStyle(colors.accent)
            Text("Workout paused").font(.title.bold())
            Text("Your workout and rest clocks are paused.").foregroundStyle(colors.muted)
            Button("Resume workout") { engine.resume(); Task { await sensor.pauseOrResume() } }
                .buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity).padding(.top, 45)
    }

    private func countdown(seconds: Int, total: Int) -> some View {
        ZStack {
            Circle().stroke(colors.border, lineWidth: 6)
            Circle().trim(from: 0, to: CGFloat(min(1, Double(seconds) / Double(max(1, total)))))
                .stroke(colors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: seconds)
            VStack(spacing: 0) {
                Text("\(seconds)").font(.system(size: 53, weight: .bold, design: .rounded)).monospacedDigit()
                Text("SECONDS").font(.caption2).tracking(1.5).foregroundStyle(colors.muted)
            }
        }.frame(width: 170, height: 170).padding(.top, 20)
    }

    private func prefill() {
        guard let exercise = engine.currentExercise else { return }
        let previous = store.previousSet(exercise: exercise.name, setNumber: engine.session?.setNumber ?? 1)
        weight = previous?.weightPounds.map { String(format: "%.1f", units == "kg" ? $0 / 2.2046226218 : $0) } ?? ""
        reps = previous?.reps.map(String.init) ?? ""
    }

    private func endWorkout(cancel: Bool) {
        let draft = engine.session
        if cancel { engine.cancel() } else { engine.finish() }
        if sensorSessionStarted { Task {
            await sensor.endWorkout(); await productStore.refresh()
            if !cancel { attachHeartRate(to: draft) }
        } }
    }

    private func beginSensorSessionIfReady() {
        guard engine.phase == "working", !sensorSessionStarted, sensor.sourceIsReady else { return }
        sensorSessionStarted = true
        if sensor.hasActiveRecording {
            if let id = sensor.recording?.draft?.id, let session = engine.session {
                session.heartRateSessionID = id
                store.persistSession(session)
            }
            return
        }
        Task {
            await sensor.startWorkout()
            if let id = sensor.recording?.draft?.id, let session = engine.session {
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
