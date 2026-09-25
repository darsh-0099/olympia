import Foundation
import Combine

/// A wall-clock driven set/rest state machine. Absolute deadlines make countdowns
/// accurate after a screen lock or normal iOS suspension; no synthetic ticks are saved.
@MainActor
final class OlympiaWorkoutEngine: ObservableObject {
    @Published private(set) var session: OlympiaTrainingSession?
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var elapsedSeconds = 0
    private weak var store: OlympiaTrainingStore?
    private var ticker: Task<Void, Never>?

    init(store: OlympiaTrainingStore) {
        self.store = store
        if let draft = store.sessions.first(where: { ["preparing", "working", "resting", "paused"].contains($0.status) }) {
            session = draft
            refreshTime()
            startTicker()
        }
    }

    var isActive: Bool { session != nil }
    var phase: String { session?.status ?? "idle" }
    var exercises: [OlympiaExercise] { session?.plannedExercises ?? [] }
    var currentExercise: OlympiaExercise? {
        guard let session, exercises.indices.contains(session.exerciseIndex) else { return nil }
        return exercises[session.exerciseIndex]
    }

    var completedSetCount: Int { session?.completedSets.count ?? 0 }
    var totalSetCount: Int { exercises.reduce(0) { $0 + $1.sets } }
    var progress: Double { totalSetCount > 0 ? Double(completedSetCount) / Double(totalSetCount) : 0 }

    func start(_ workout: OlympiaWorkoutTemplate) {
        guard session == nil, let store, !workout.exercises.isEmpty else { return }
        let draft = store.createSession(for: workout)
        draft.phaseDeadline = .now.addingTimeInterval(120)
        store.persistSession(draft)
        session = draft
        refreshTime(); startTicker()
    }

    func beginNow() {
        guard let session, session.status == "preparing" else { return }
        session.startedAt = .now // Equipment prep is not workout time.
        session.status = "working"
        session.phaseDeadline = nil
        store?.persistSession(session)
        refreshTime()
    }

    func completeSet(weightPounds: Double?, reps: Int?) {
        guard let session, session.status == "working", let exercise = currentExercise else { return }
        let value = weightPounds.flatMap { $0 >= 0 && $0 <= 2000 ? $0 : nil }
        let repetitions = reps.flatMap { $0 >= 0 && $0 <= 1000 ? $0 : nil }
        guard value != nil || repetitions != nil else { return }
        var sets = session.completedSets
        sets.append(OlympiaCompletedSet(exerciseName: exercise.name,
                                         exercisePosition: session.exerciseIndex,
                                         setNumber: session.setNumber,
                                         weightPounds: value, reps: repetitions,
                                         restSeconds: exercise.restSeconds,
                                         completedAt: .now))
        session.completedSets = sets
        let isLastSet = session.setNumber >= exercise.sets
        let isLastExercise = session.exerciseIndex >= exercises.count - 1
        if isLastSet && isLastExercise { finish(); return }
        if isLastSet { session.exerciseIndex += 1; session.setNumber = 1 }
        else { session.setNumber += 1 }
        session.status = "resting"
        session.phaseDeadline = .now.addingTimeInterval(TimeInterval(max(0, exercise.restSeconds)))
        store?.persistSession(session)
        refreshTime()
    }

    func adjustRest(by seconds: Int) {
        guard let session, session.status == "resting" else { return }
        let remaining = max(5, Int((session.phaseDeadline ?? .now).timeIntervalSinceNow.rounded(.up)) + seconds)
        session.phaseDeadline = .now.addingTimeInterval(TimeInterval(remaining))
        store?.persistSession(session)
        refreshTime()
    }

    func skipRest() {
        guard let session, session.status == "resting" else { return }
        session.status = "working"; session.phaseDeadline = nil
        store?.persistSession(session); refreshTime()
    }

    func pause() {
        guard let session, ["working", "resting"].contains(session.status) else { return }
        session.pausedPhase = session.status
        session.pausedRemaining = max(0, (session.phaseDeadline ?? .now).timeIntervalSinceNow)
        session.phaseDeadline = nil; session.pausedAt = .now; session.status = "paused"
        store?.persistSession(session); refreshTime()
    }

    func resume() {
        guard let session, session.status == "paused" else { return }
        if let pausedAt = session.pausedAt {
            session.totalPausedSeconds += Date().timeIntervalSince(pausedAt)
        }
        session.pausedAt = nil
        session.status = session.pausedPhase ?? "working"
        if session.status == "resting" {
            session.phaseDeadline = .now.addingTimeInterval(session.pausedRemaining)
        }
        session.pausedPhase = nil; session.pausedRemaining = 0
        store?.persistSession(session); refreshTime()
    }

    func finish() {
        guard let session else { return }
        if session.status == "paused", let pausedAt = session.pausedAt {
            session.totalPausedSeconds += Date().timeIntervalSince(pausedAt)
        }
        session.pausedAt = nil; session.phaseDeadline = nil; session.endedAt = .now
        session.status = session.completedSets.count >= totalSetCount ? "completed" : "partial"
        store?.persistSession(session)
        self.session = nil
        ticker?.cancel(); ticker = nil
    }

    func cancel() {
        guard let session else { return }
        if session.completedSets.isEmpty { store?.deleteSession(session) }
        else { finish(); return }
        self.session = nil
        ticker?.cancel(); ticker = nil
    }

    func refreshTime() {
        guard let session else { return }
        elapsedSeconds = max(0, Int(session.duration.rounded(.down)))
        if let deadline = session.phaseDeadline {
            secondsRemaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            if secondsRemaining == 0 {
                if session.status == "preparing" { beginNow() }
                else if session.status == "resting" { skipRest() }
            }
        } else if session.status == "paused" {
            secondsRemaining = max(0, Int(session.pausedRemaining.rounded(.up)))
        } else { secondsRemaining = 0 }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, self?.session != nil {
                self?.refreshTime()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
