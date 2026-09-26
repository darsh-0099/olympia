import Foundation

struct OlympiaImportReport {
    var sessions = 0
    var sets = 0
    var weights = 0
    var skipped = 0
}

@MainActor enum OlympiaNoteImporter {
    static func importWorkouts(_ text: String, into store: OlympiaTrainingStore) -> OlympiaImportReport {
        var report = OlympiaImportReport()
        var title = ""
        var date: Date?
        var sets: [OlympiaCompletedSet] = []
        var position = 0
        func flush() {
            if let date, !sets.isEmpty {
                store.addImportedSession(name: title, date: date, sets: sets)
                report.sessions += 1; report.sets += sets.count
            }
            sets = []; position = 0
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // A workout header ends with its date. Exercise rows can contain
            // date-shaped rep sequences (even valid dates such as 12/10/10).
            if !line.contains(" - "),
               firstMatch(#"^\d+[.)]\s*"#, in: line) == nil,
               let found = firstMatch(#"^(.*?)\b(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})\s*:?$"#, in: line) {
                flush()
                date = strictDate(month: found[2], day: found[3], year: found[4])
                title = found[1]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :,-"))
                if title.isEmpty { title = "Workout" }
                if date == nil { report.skipped += 1 }
                continue
            }
            guard let workoutDate = date else { report.skipped += 1; continue }
            let content = line.replacingOccurrences(of: #"^\d+[.)]\s*"#, with: "", options: .regularExpression)
            let parts = content.components(separatedBy: " - ")
            guard let exercise = parts.first?.trimmingCharacters(in: .whitespaces), !exercise.isEmpty else {
                report.skipped += 1; continue
            }
            position += 1
            let explicit = firstMatch(#"(\d+)\s*sets?"#, in: content.lowercased()).flatMap { Int($0[1]) }
                ?? (parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil)
            let repsChunk = parts.dropFirst().first { $0.contains("/") || $0.lowercased().contains("rep") } ?? ""
            let slashReps = firstMatch(#"\b\d+(?:\s*/\s*\d+)+\b"#, in: repsChunk)?[0]
                .components(separatedBy: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []
            let fixedReps = firstMatch(#"\b(\d+(?:\.\d+)?)\s*reps?\b"#, in: content.lowercased())
                .flatMap { Double($0[1]).map { Int($0.rounded()) } }
            // Notes such as "4 sets - 12 reps (Last set 15)" describe a
            // different final set; preserving it matters in workout history.
            let finalSetReps = firstMatch(#"\blast\s+set\s+(\d+(?:\.\d+)?)\b"#, in: content.lowercased())
                .flatMap { Double($0[1]).map { Int($0.rounded()) } }
            let count = min(20, max(1, explicit ?? (slashReps.isEmpty ? 1 : slashReps.count)))
            let weight = firstMatch(#"(\d+(?:\.\d+)?)\s*(?:lbs?|pounds?|kg)\b"#, in: content.lowercased())
                .flatMap { Double($0[1]) }
            let pounds = content.lowercased().contains("kg") ? weight.map { $0 * 2.2046226218 } : weight
            for index in 0..<count {
                sets.append(OlympiaCompletedSet(exerciseName: exercise, exercisePosition: position - 1,
                                                setNumber: index + 1, weightPounds: pounds,
                                                reps: index == count - 1 ? (finalSetReps ?? (index < slashReps.count ? slashReps[index] : fixedReps))
                                                    : (index < slashReps.count ? slashReps[index] : fixedReps),
                                                restSeconds: 0, completedAt: workoutDate))
            }
        }
        flush()
        return report
    }

    static func importWeights(_ text: String, into store: OlympiaTrainingStore) -> OlympiaImportReport {
        var report = OlympiaImportReport()
        for line in text.components(separatedBy: .newlines) {
            guard let dateParts = firstMatch(#"\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b"#, in: line),
                  let valueParts = firstMatch(#"(\d{2,3}(?:\.\d+)?)\s*(lb|lbs|pounds|kg)\b"#, in: line.lowercased()) else {
                report.skipped += 1; continue
            }
            guard let date = strictDate(month: dateParts[1], day: dateParts[2], year: dateParts[3]),
                  let value = Double(valueParts[1]) else { report.skipped += 1; continue }
            if !store.importedWeightExists(on: date) {
                store.logWeight(value, kilograms: valueParts[2] == "kg", at: date)
                report.weights += 1
            }
        }
        return report
    }

    private static func strictDate(month: String, day: String, year: String) -> Date? {
        guard let month = Int(month), let day = Int(day), let rawYear = Int(year),
              year.count == 2 || year.count == 4 else { return nil }
        let year = rawYear < 100 ? 2000 + rawYear : rawYear
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        // Calendar.date(from:) normalizes overflow (for example February 30).
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return date
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}

struct OlympiaBackup: Codable {
    struct Workout: Codable { var id: UUID; var name: String; var colorHex: String; var exercises: [OlympiaExercise] }
    struct Session: Codable { var id: UUID; var name: String; var startedAt: Date; var endedAt: Date?; var status: String; var averageHeartRate: Double?; var sets: [OlympiaCompletedSet] }
    struct Program: Codable { var id: UUID; var name: String; var scheduleType: String; var rotationRestDays: Int; var rotationAnchor: Date; var scheduleShiftDays: Int; var slots: [OlympiaProgramSlot] }
    struct Weight: Codable { var id: UUID; var measuredAt: Date; var pounds: Double }
    var workouts: [Workout]
    var sessions: [Session]
    var programs: [Program]
    var weights: [Weight]

    @MainActor init(store: OlympiaTrainingStore) {
        workouts = store.workouts.map { Workout(id: $0.id, name: $0.name, colorHex: $0.colorHex, exercises: $0.exercises) }
        sessions = store.sessions.map { Session(id: $0.id, name: $0.name, startedAt: $0.startedAt,
                                                endedAt: $0.endedAt, status: $0.status,
                                                averageHeartRate: $0.averageHeartRate, sets: $0.completedSets) }
        programs = store.programs.map { Program(id: $0.id, name: $0.name, scheduleType: $0.scheduleType,
                                                rotationRestDays: $0.rotationRestDays, rotationAnchor: $0.rotationAnchor,
                                                scheduleShiftDays: $0.scheduleShiftDays,
                                                slots: $0.slots) }
        weights = store.weights.map { Weight(id: $0.id, measuredAt: $0.measuredAt, pounds: $0.pounds) }
    }
}
