import Foundation
import SwiftData
import Combine

func olympiaExerciseKey(_ name: String) -> String {
    var key = name.lowercased().filter(\.isLetter)
    if key.hasSuffix("s"), !key.hasSuffix("ss") { key.removeLast() }
    return key
}

struct OlympiaExercise: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var sets: Int
    var restSeconds: Int
}

struct OlympiaProgramSlot: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var workoutID: UUID
    var weekdays: [Int] // Calendar weekday: Sunday = 1.
    var colorHex: String
}

struct OlympiaCompletedSet: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var exerciseName: String
    var exercisePosition: Int
    var setNumber: Int
    var weightPounds: Double?
    var reps: Int?
    var restSeconds: Int
    var completedAt: Date
}

@Model final class OlympiaWorkoutTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var exercisesData: Data
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, colorHex: String = "#63C7FF", exercises: [OlympiaExercise]) {
        self.id = id; self.name = name; self.colorHex = colorHex
        self.exercisesData = (try? JSONEncoder().encode(exercises)) ?? Data()
        self.createdAt = .now; self.updatedAt = .now
    }

    var exercises: [OlympiaExercise] {
        get { (try? JSONDecoder().decode([OlympiaExercise].self, from: exercisesData)) ?? [] }
        set { exercisesData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }
}

@Model final class OlympiaProgram {
    @Attribute(.unique) var id: UUID
    var name: String
    var scheduleType: String
    var rotationRestDays: Int
    var rotationAnchor: Date
    var scheduleShiftDays: Int
    var slotsData: Data
    var isActive: Bool
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, scheduleType: String = "weekly", rotationRestDays: Int = 0,
         rotationAnchor: Date = .now, scheduleShiftDays: Int = 0,
         slots: [OlympiaProgramSlot], isActive: Bool = true) {
        self.id = id; self.name = name; self.scheduleType = scheduleType
        self.rotationRestDays = max(0, min(7, rotationRestDays))
        self.rotationAnchor = rotationAnchor
        self.scheduleShiftDays = scheduleShiftDays
        self.slotsData = (try? JSONEncoder().encode(slots)) ?? Data()
        self.isActive = isActive; self.updatedAt = .now
    }

    var slots: [OlympiaProgramSlot] {
        get { (try? JSONDecoder().decode([OlympiaProgramSlot].self, from: slotsData)) ?? [] }
        set { slotsData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }
}

@Model final class OlympiaTrainingSession {
    @Attribute(.unique) var id: UUID
    var workoutID: UUID?
    var name: String
    var heartRateSessionID: UUID?
    var averageHeartRate: Double?
    var startedAt: Date
    var endedAt: Date?
    var status: String // preparing, working, resting, paused, completed, partial, imported
    var plannedExercisesData: Data
    var completedSetsData: Data
    var exerciseIndex: Int
    var setNumber: Int
    var phaseDeadline: Date?
    var pausedRemaining: TimeInterval
    var pausedAt: Date?
    var pausedPhase: String?
    var totalPausedSeconds: TimeInterval

    init(id: UUID = UUID(), workoutID: UUID? = nil, name: String, startedAt: Date = .now,
         plannedExercises: [OlympiaExercise] = [],
         status: String = "preparing", sets: [OlympiaCompletedSet] = []) {
        self.id = id; self.workoutID = workoutID; self.name = name
        self.heartRateSessionID = nil; self.averageHeartRate = nil; self.startedAt = startedAt
        self.plannedExercisesData = (try? JSONEncoder().encode(plannedExercises)) ?? Data()
        self.status = status; self.completedSetsData = (try? JSONEncoder().encode(sets)) ?? Data()
        self.exerciseIndex = 0; self.setNumber = 1
        self.phaseDeadline = nil; self.pausedRemaining = 0; self.pausedAt = nil; self.pausedPhase = nil
        self.totalPausedSeconds = 0
    }

    var completedSets: [OlympiaCompletedSet] {
        get { (try? JSONDecoder().decode([OlympiaCompletedSet].self, from: completedSetsData)) ?? [] }
        set { completedSetsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var plannedExercises: [OlympiaExercise] {
        (try? JSONDecoder().decode([OlympiaExercise].self, from: plannedExercisesData)) ?? []
    }

    var duration: TimeInterval {
        (endedAt ?? pausedAt ?? .now).timeIntervalSince(startedAt) - totalPausedSeconds
    }
}

@Model final class OlympiaBodyWeight {
    @Attribute(.unique) var id: UUID
    var measuredAt: Date
    var pounds: Double

    init(id: UUID = UUID(), measuredAt: Date = .now, pounds: Double) {
        self.id = id; self.measuredAt = measuredAt; self.pounds = pounds
    }
}

@MainActor
final class OlympiaTrainingStore: ObservableObject {
    let container: ModelContainer
    private let context: ModelContext
    @Published private(set) var workouts: [OlympiaWorkoutTemplate] = []
    @Published private(set) var programs: [OlympiaProgram] = []
    @Published private(set) var sessions: [OlympiaTrainingSession] = []
    @Published private(set) var weights: [OlympiaBodyWeight] = []
    @Published var errorMessage: String?

    init(inMemory: Bool = false) throws {
        container = try ModelContainer(for: OlympiaWorkoutTemplate.self, OlympiaProgram.self,
                                       OlympiaTrainingSession.self, OlympiaBodyWeight.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        context = container.mainContext
        refresh()
    }

    func refresh() {
        do {
            workouts = try context.fetch(FetchDescriptor<OlympiaWorkoutTemplate>())
                .sorted { $0.createdAt < $1.createdAt }
            programs = try context.fetch(FetchDescriptor<OlympiaProgram>())
                .sorted { $0.updatedAt > $1.updatedAt }
            sessions = try context.fetch(FetchDescriptor<OlympiaTrainingSession>())
                .sorted { $0.startedAt > $1.startedAt }
            weights = try context.fetch(FetchDescriptor<OlympiaBodyWeight>())
                .sorted { $0.measuredAt < $1.measuredAt }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        do { try context.save(); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func upsertWorkout(id: UUID? = nil, name: String, colorHex: String, exercises: [OlympiaExercise]) {
        let clean = exercises.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !clean.isEmpty else { return }
        if let existing = workouts.first(where: { $0.id == id }) {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.colorHex = colorHex; existing.exercises = clean
        } else { context.insert(OlympiaWorkoutTemplate(name: name, colorHex: colorHex, exercises: clean)) }
        save()
    }

    func deleteWorkout(_ workout: OlympiaWorkoutTemplate) {
        for program in programs {
            program.slots = program.slots.filter { $0.workoutID != workout.id }
        }
        context.delete(workout)
        save() // Historical sessions retain their exercise and set details.
    }

    func upsertProgram(id: UUID? = nil, name: String, scheduleType: String,
                       rotationRestDays: Int, slots: [OlympiaProgramSlot]) {
        guard !slots.isEmpty else { return }
        for program in programs { program.isActive = false }
        if let existing = programs.first(where: { $0.id == id }) {
            existing.name = name; existing.scheduleType = scheduleType
            existing.rotationRestDays = max(0, min(7, rotationRestDays))
            existing.slots = slots; existing.isActive = true; existing.updatedAt = .now
        } else {
            context.insert(OlympiaProgram(name: name, scheduleType: scheduleType,
                                          rotationRestDays: rotationRestDays, slots: slots))
        }
        save()
    }

    var activeProgram: OlympiaProgram? { programs.first(where: { $0.isActive }) }

    func scheduledWorkouts(on date: Date, calendar: Calendar = .current) -> [OlympiaWorkoutTemplate] {
        guard let program = activeProgram else { return [] }
        let slots = program.slots
        guard !slots.isEmpty else { return [] }
        let selected: [OlympiaProgramSlot]
        if program.scheduleType == "rotation" {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: program.rotationAnchor),
                                               to: calendar.startOfDay(for: date)).day ?? 0
            let cycle = slots.count + max(0, min(7, program.rotationRestDays))
            let index = ((days % cycle) + cycle) % cycle
            selected = index < slots.count ? [slots[index]] : []
        } else {
            let shiftedDate = calendar.date(byAdding: .day, value: -program.scheduleShiftDays, to: date) ?? date
            let weekday = calendar.component(.weekday, from: shiftedDate)
            selected = slots.filter { $0.weekdays.contains(weekday) }
        }
        return selected.compactMap { slot in workouts.first(where: { $0.id == slot.workoutID }) }
    }

    func postponeRotationOneDay() {
        guard let program = activeProgram else { return }
        if program.scheduleType == "rotation" {
            program.rotationAnchor = Calendar.current.date(byAdding: .day, value: 1, to: program.rotationAnchor) ?? program.rotationAnchor
        } else {
            program.scheduleShiftDays += 1
        }
        program.updatedAt = .now
        save()
    }

    @discardableResult
    func createSession(for workout: OlympiaWorkoutTemplate) -> OlympiaTrainingSession {
        let session = OlympiaTrainingSession(workoutID: workout.id, name: workout.name,
                                             plannedExercises: workout.exercises)
        context.insert(session); save(); return session
    }

    func persistSession(_ session: OlympiaTrainingSession) { save() }

    func deleteSession(_ session: OlympiaTrainingSession) { context.delete(session); save() }

    func deleteExercise(_ name: String, from session: OlympiaTrainingSession) {
        session.completedSets = session.completedSets.filter { $0.exerciseName != name }
        save()
    }

    func logWeight(_ value: Double, kilograms: Bool, at date: Date = .now) {
        let pounds = kilograms ? value * 2.2046226218 : value
        guard pounds >= 50, pounds <= 500 else { errorMessage = "Enter a weight between 50 and 500 lb."; return }
        context.insert(OlympiaBodyWeight(measuredAt: date, pounds: pounds))
        save()
    }

    func deleteWeight(_ entry: OlympiaBodyWeight) { context.delete(entry); save() }

    func previousSet(exercise: String, setNumber: Int) -> OlympiaCompletedSet? {
        let key = olympiaExerciseKey(exercise)
        return sessions.flatMap { $0.completedSets }
            .filter { olympiaExerciseKey($0.exerciseName) == key && $0.setNumber == setNumber }
            .sorted { $0.completedAt > $1.completedAt }.first
    }

    func historyExercises() -> [String] {
        var byKey: [String: String] = [:]
        for name in sessions.flatMap({ $0.completedSets.map(\.exerciseName) }) +
                    workouts.flatMap({ $0.exercises.map(\.name) }) {
            let key = olympiaExerciseKey(name)
            if byKey[key] == nil { byKey[key] = name }
        }
        return byKey.values.sorted()
    }

    func addImportedSession(name: String, date: Date, sets: [OlympiaCompletedSet]) {
        guard !sets.isEmpty else { return }
        if let existing = sessions.first(where: {
            $0.status == "imported" && $0.name == name &&
            Calendar.current.isDate($0.startedAt, inSameDayAs: date)
        }) {
            existing.completedSets = sets
        } else {
            let session = OlympiaTrainingSession(name: name, startedAt: date, status: "imported", sets: sets)
            session.endedAt = date
            context.insert(session)
        }
        save()
    }

    func importedWeightExists(on date: Date) -> Bool {
        weights.contains { Calendar.current.isDate($0.measuredAt, inSameDayAs: date) }
    }

    func mergeBackup(_ backup: OlympiaBackup) {
        for item in backup.workouts where !workouts.contains(where: { $0.id == item.id }) {
            context.insert(OlympiaWorkoutTemplate(id: item.id, name: item.name,
                                                  colorHex: item.colorHex, exercises: item.exercises))
        }
        for item in backup.programs where !programs.contains(where: { $0.id == item.id }) {
            context.insert(OlympiaProgram(id: item.id, name: item.name,
                                          scheduleType: item.scheduleType,
                                          rotationRestDays: item.rotationRestDays,
                                          rotationAnchor: item.rotationAnchor,
                                          scheduleShiftDays: item.scheduleShiftDays,
                                          slots: item.slots, isActive: programs.isEmpty))
        }
        for item in backup.sessions where !sessions.contains(where: { $0.id == item.id }) {
            let session = OlympiaTrainingSession(id: item.id, name: item.name,
                                                 startedAt: item.startedAt, status: item.status, sets: item.sets)
            session.endedAt = item.endedAt
            session.averageHeartRate = item.averageHeartRate
            context.insert(session)
        }
        for item in backup.weights where !weights.contains(where: { $0.id == item.id }) {
            context.insert(OlympiaBodyWeight(id: item.id, measuredAt: item.measuredAt, pounds: item.pounds))
        }
        save()
    }
}
