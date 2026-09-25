import Foundation

struct HRVConfiguration: Codable, Equatable, Sendable {
    let algorithmVersion: String
    let minimumRRMilliseconds: Double
    let maximumRRMilliseconds: Double
    let localMedianWindow: Int
    let maximumRelativeDeviation: Double
    let minimumAcceptedBeats: Int
    let minimumDurationSeconds: Double
    let minimumAcceptedFraction: Double

    static let restingV1 = HRVConfiguration(
        algorithmVersion: "hrv-resting-v1", minimumRRMilliseconds: 300, maximumRRMilliseconds: 2_000,
        localMedianWindow: 5, maximumRelativeDeviation: 0.20, minimumAcceptedBeats: 120,
        minimumDurationSeconds: 180, minimumAcceptedFraction: 0.80
    )

    static let sessionV1 = HRVConfiguration(
        algorithmVersion: "hrv-session-v1", minimumRRMilliseconds: 300, maximumRRMilliseconds: 2_000,
        localMedianWindow: 5, maximumRelativeDeviation: 0.20, minimumAcceptedBeats: 60,
        minimumDurationSeconds: 60, minimumAcceptedFraction: 0.80
    )
}

enum RRExclusionReason: String, Codable, Sendable { case physiologicBounds, localMedianArtifact }

struct RRExclusion: Equatable, Sendable {
    let sampleID: UUID
    let reason: RRExclusionReason
}

struct HRVAnalysis: Equatable, Sendable {
    let meanRRMilliseconds: MetricResult
    let rmssdMilliseconds: MetricResult
    let sdnnMilliseconds: MetricResult
    let pNN50Percent: MetricResult
    let lnRMSSD: MetricResult
    let acceptedCount: Int
    let artifactCount: Int
    let acceptedFraction: Double
    let acceptedDurationSeconds: Double
    let quality: DataQualityLevel
    let exclusions: [RRExclusion]
}

enum HRVEngine {
    /// Raw RR values remain immutable. Stage one applies inclusive 300...2000 ms
    /// bounds. Stage two rejects values differing by more than 20% from the
    /// median of up to five neighboring, in-bounds values (excluding itself).
    static func analyze(
        _ samples: [RRIntervalValue],
        context: MeasurementPurpose,
        configuration: HRVConfiguration
    ) throws -> HRVAnalysis {
        try analyze(segments: [samples], context: context, configuration: configuration)
    }

    static func analyze(
        segments: [[RRIntervalValue]],
        context: MeasurementPurpose,
        configuration: HRVConfiguration
    ) throws -> HRVAnalysis {
        guard configuration.minimumRRMilliseconds.isFinite, configuration.maximumRRMilliseconds.isFinite,
              configuration.minimumRRMilliseconds > 0,
              configuration.maximumRRMilliseconds > configuration.minimumRRMilliseconds,
              configuration.localMedianWindow >= 3,
              configuration.maximumRelativeDeviation.isFinite,
              configuration.maximumRelativeDeviation >= 0,
              configuration.minimumAcceptedBeats >= 2,
              configuration.minimumDurationSeconds.isFinite, configuration.minimumDurationSeconds >= 0,
              configuration.minimumAcceptedFraction.isFinite,
              (0...1).contains(configuration.minimumAcceptedFraction) else {
            throw MetricsInputError.invalidConfiguration
        }
        var exclusions: [RRExclusion] = []
        let halfWindow = max(1, configuration.localMedianWindow / 2)
        var accepted: [RRIntervalValue] = []
        var differences: [Double] = []
        var totalInputCount = 0
        for segment in segments {
            let ordered = segment.enumerated().sorted {
                let left = $0.element.derivedBeatMonotonicNanoseconds ?? $0.element.receivedMonotonicNanoseconds
                let right = $1.element.derivedBeatMonotonicNanoseconds ?? $1.element.receivedMonotonicNanoseconds
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            totalInputCount += ordered.count
            let boundedIndices = ordered.indices.filter { index in
                let value = ordered[index].milliseconds
                let valid = value >= configuration.minimumRRMilliseconds &&
                    value <= configuration.maximumRRMilliseconds && value.isFinite
                if !valid { exclusions.append(.init(sampleID: ordered[index].id, reason: .physiologicBounds)) }
                return valid
            }
            var acceptedIndices: Set<Int> = []
            for (position, originalIndex) in boundedIndices.enumerated() {
                let lower = max(0, position - halfWindow)
                let upper = min(boundedIndices.count, position + halfWindow + 1)
                let neighbors = boundedIndices[lower..<upper]
                    .filter { $0 != originalIndex }.map { ordered[$0].milliseconds }
                if neighbors.count >= 2 {
                    let localMedian = median(neighbors)
                    if abs(ordered[originalIndex].milliseconds - localMedian) / localMedian > configuration.maximumRelativeDeviation {
                        exclusions.append(.init(sampleID: ordered[originalIndex].id, reason: .localMedianArtifact))
                        continue
                    }
                }
                accepted.append(ordered[originalIndex]); acceptedIndices.insert(originalIndex)
            }
            if ordered.count >= 2 {
                for index in 1..<ordered.count where acceptedIndices.contains(index - 1) && acceptedIndices.contains(index) {
                    differences.append(ordered[index].milliseconds - ordered[index - 1].milliseconds)
                }
            }
        }

        let acceptedValues = accepted.map(\.milliseconds)
        let acceptedFraction = totalInputCount == 0 ? 0 : Double(accepted.count) / Double(totalInputCount)
        let duration = acceptedValues.reduce(0, +) / 1_000
        var quality: DataQualityLevel = acceptedFraction >= 0.95 ? .good : acceptedFraction >= 0.80 ? .fair : .poor
        let unavailableReason: String? = {
            if accepted.count < configuration.minimumAcceptedBeats { return "Not enough accepted RR intervals" }
            if duration < configuration.minimumDurationSeconds { return "Accepted RR duration is too short" }
            if acceptedFraction < configuration.minimumAcceptedFraction { return "Too many RR intervals were excluded" }
            return nil
        }()
        if unavailableReason != nil { quality = .insufficient }
        let lineage = MetricLineage(sampleOrigins: Set(accepted.map(\.origin)))
        let qualityReasons = quality == .good ? [] : ["Accepted RR fraction is below 95%"]
        let make: (String, String, Double?) throws -> MetricResult = { key, unit, value in
            if let unavailableReason {
                return try MetricResult(id: key, name: key, value: nil, unit: unit, classification: .unavailable,
                                        context: context, lineage: lineage,
                                        algorithmVersion: configuration.algorithmVersion,
                                        configurationVersion: "rr-filter-v1", quality: .insufficient,
                                        reasons: [unavailableReason])
            }
            guard let value else {
                return try MetricResult(id: key, name: key, value: nil, unit: unit, classification: .unavailable,
                                        context: context, lineage: lineage,
                                        algorithmVersion: configuration.algorithmVersion,
                                        configurationVersion: "rr-filter-v1", quality: .insufficient,
                                        reasons: ["Metric requires at least two accepted RR intervals"])
            }
            return try MetricResult(id: key, name: key, value: value, unit: unit, classification: .calculated,
                                    context: context, lineage: lineage,
                                    algorithmVersion: configuration.algorithmVersion,
                                    configurationVersion: "rr-filter-v1", quality: quality, reasons: qualityReasons)
        }

        let mean = acceptedValues.isEmpty ? nil : acceptedValues.reduce(0, +) / Double(acceptedValues.count)
        let rmssd = differences.isEmpty ? nil : sqrt(differences.map { $0 * $0 }.reduce(0, +) / Double(differences.count))
        let sampleSDNN: Double? = {
            guard acceptedValues.count >= 2, let mean else { return nil }
            return sqrt(acceptedValues.map { pow($0 - mean, 2) }.reduce(0, +) / Double(acceptedValues.count - 1))
        }()
        let pNN50 = differences.isEmpty ? nil : 100 * Double(differences.filter { abs($0) > 50 }.count) / Double(differences.count)
        let lnRMSSD = rmssd.flatMap { $0 > 0 ? log($0) : nil }
        return HRVAnalysis(
            meanRRMilliseconds: try make("mean_rr", "ms", mean),
            rmssdMilliseconds: try make("rmssd", "ms", rmssd),
            sdnnMilliseconds: try make("sdnn", "ms", sampleSDNN),
            pNN50Percent: try make("pnn50", "%", pNN50),
            lnRMSSD: try make("ln_rmssd", "ln(ms)", lnRMSSD),
            acceptedCount: accepted.count, artifactCount: exclusions.count,
            acceptedFraction: acceptedFraction, acceptedDurationSeconds: duration,
            quality: quality, exclusions: exclusions
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

enum ZoneBoundarySource: String, Codable, Equatable, Sendable { case measured, estimated, unavailable }

struct HeartRateZoneConfiguration: Codable, Equatable, Sendable {
    let version: String
    let maximumHeartRate: Int
    let source: ZoneBoundarySource
    let effectiveAtUTC: Date
    let lowerFractions: [Double]

    static func standard(maximumHeartRate: Int, source: ZoneBoundarySource, effectiveAtUTC: Date) -> Self {
        .init(version: "zones-v1", maximumHeartRate: maximumHeartRate, source: source,
              effectiveAtUTC: effectiveAtUTC, lowerFractions: [0.50, 0.60, 0.70, 0.80, 0.90])
    }

    func zone(for bpm: Int) -> Int? {
        guard maximumHeartRate > 0, bpm >= 0, lowerFractions.count == 5,
              zip(lowerFractions, lowerFractions.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { return nil }
        let fraction = Double(bpm) / Double(maximumHeartRate)
        guard fraction >= lowerFractions[0] else { return 0 }
        for index in stride(from: 4, through: 0, by: -1) where fraction >= lowerFractions[index] { return index + 1 }
        return nil
    }
}

struct ZoneLoadResult: Equatable, Sendable {
    let secondsByZone: [Int: Double]
    let activeSeconds: Double
    let coveredSeconds: Double
    let coverageFraction: Double
    let edwardsTRIMP: MetricResult
}

struct ActiveHeartRateSegment: Equatable, Sendable {
    let samples: [HeartRateSampleValue]
    let startMonotonicNanoseconds: UInt64
    let endMonotonicNanoseconds: UInt64

    init(samples: [HeartRateSampleValue], startMonotonicNanoseconds: UInt64,
         endMonotonicNanoseconds: UInt64) throws {
        guard endMonotonicNanoseconds >= startMonotonicNanoseconds,
              samples.allSatisfy({ $0.receivedMonotonicNanoseconds >= startMonotonicNanoseconds &&
                  $0.receivedMonotonicNanoseconds <= endMonotonicNanoseconds }) else {
            throw MetricsInputError.invalidSegments
        }
        self.samples = samples
        self.startMonotonicNanoseconds = startMonotonicNanoseconds
        self.endMonotonicNanoseconds = endMonotonicNanoseconds
    }
}

enum MetricsInputError: Error, Equatable { case invalidSegments, invalidConfiguration }

enum TrainingLoadEngine {
    /// Each HR sample owns time until the next sample. Intervals over five
    /// seconds are gaps and contribute nothing. Edwards weights are 1...5;
    /// below-zone time has weight zero.
    static func calculate(segments: [ActiveHeartRateSegment], zones: HeartRateZoneConfiguration) throws -> ZoneLoadResult {
        guard !zones.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              zones.maximumHeartRate > 0, zones.lowerFractions.count == 5,
              zones.lowerFractions.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
              zip(zones.lowerFractions, zones.lowerFractions.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw MetricsInputError.invalidConfiguration
        }
        let chronological = segments.sorted { $0.startMonotonicNanoseconds < $1.startMonotonicNanoseconds }
        guard zip(chronological, chronological.dropFirst()).allSatisfy({ $0.0.endMonotonicNanoseconds <= $0.1.startMonotonicNanoseconds }) else {
            throw MetricsInputError.invalidSegments
        }
        var seconds: [Int: Double] = [:]
        var activeSeconds = 0.0
        var coveredSeconds = 0.0
        let samples = segments.flatMap(\.samples)
        for segment in segments {
            guard segment.endMonotonicNanoseconds >= segment.startMonotonicNanoseconds else { continue }
            activeSeconds += Double(segment.endMonotonicNanoseconds - segment.startMonotonicNanoseconds) / 1_000_000_000
            let ordered = segment.samples.sorted { $0.receivedMonotonicNanoseconds < $1.receivedMonotonicNanoseconds }
            for (index, current) in ordered.enumerated() {
                let end = index + 1 < ordered.count ? ordered[index + 1].receivedMonotonicNanoseconds : segment.endMonotonicNanoseconds
                guard end >= current.receivedMonotonicNanoseconds else { continue }
                let delta = Double(end - current.receivedMonotonicNanoseconds) / 1_000_000_000
                guard delta <= 5, let zone = zones.zone(for: current.beatsPerMinute) else { continue }
                coveredSeconds += delta
                seconds[zone, default: 0] += delta
            }
        }
        let trimp = seconds.reduce(0) { $0 + ($1.value / 60) * Double($1.key) }
        let lineage = MetricLineage(sampleOrigins: Set(samples.map(\.origin)))
        let estimatedZones = zones.source == .estimated
        let metric: MetricResult
        let coverage = activeSeconds > 0 ? coveredSeconds / activeSeconds : 0
        if zones.source == .unavailable {
            metric = try MetricResult(id: "edwards_trimp", name: "Cardiovascular load", value: nil,
                                      unit: "AU", classification: .unavailable, context: .exerciseSession,
                                      lineage: lineage, algorithmVersion: "edwards-trimp-v1",
                                      configurationVersion: zones.version, quality: .insufficient,
                                      reasons: ["Heart-rate zones are unavailable"])
        } else if samples.isEmpty || activeSeconds <= 0 || coverage < 0.70 {
            metric = try MetricResult(id: "edwards_trimp", name: "Cardiovascular load", value: nil,
                                      unit: "AU", classification: .unavailable, context: .exerciseSession,
                                      lineage: lineage, algorithmVersion: "edwards-trimp-v1",
                                      configurationVersion: zones.version, quality: .insufficient,
                                      reasons: ["Heart-rate coverage is below 70% of active time"])
        } else {
            let fairCoverage = coverage < 0.90
            let quality: DataQualityLevel = (estimatedZones || fairCoverage) ? .fair : .good
            var reasons: [String] = []
            if estimatedZones { reasons.append("Zone boundaries use an estimated maximum heart rate") }
            if fairCoverage { reasons.append("Heart-rate coverage is below 90% of active time") }
            metric = try MetricResult(id: "edwards_trimp", name: "Cardiovascular load", value: trimp,
                                      unit: "AU", classification: .calculated, context: .exerciseSession,
                                      lineage: lineage, algorithmVersion: "edwards-trimp-v1",
                                      configurationVersion: zones.version, quality: quality, reasons: reasons)
        }
        return .init(secondsByZone: seconds, activeSeconds: activeSeconds, coveredSeconds: coveredSeconds,
                     coverageFraction: coverage, edwardsTRIMP: metric)
    }
}

enum RecoveryMode: String, Codable, Sendable { case seated, standing }
struct RecoveryResult: Equatable, Sendable {
    let startBPM: Int
    let recoveryBPM: Int
    let dropBPM: Int
    let mode: RecoveryMode
    let coveredSamples: Int
}
struct RecoveryAssessment: Equatable, Sendable {
    let metric: MetricResult
    let detail: RecoveryResult?
}

enum HeartRateRecoveryEngine {
    static func oneMinute(samples: [HeartRateSampleValue], exerciseEndedAtUTC: Date,
                          exerciseEndedMonotonicNanoseconds: UInt64,
                          mode: RecoveryMode, toleranceSeconds: Double = 5,
                          interruptions: [InterruptionMarker] = []) throws -> RecoveryAssessment {
        let ordered = samples.sorted { $0.receivedMonotonicNanoseconds < $1.receivedMonotonicNanoseconds }
        let lineage = MetricLineage(sampleOrigins: Set(ordered.map(\.origin)))
        let unavailable: (String) throws -> RecoveryAssessment = { reason in
            .init(metric: try MetricResult(id: "heart_rate_recovery_1m", name: "One-minute heart-rate recovery",
                  value: nil, unit: "bpm", classification: .unavailable, context: .exerciseSession,
                  lineage: lineage, algorithmVersion: "recovery-v1", configurationVersion: "\(mode.rawValue)-60s-v1",
                  quality: .insufficient, reasons: [reason]), detail: nil)
        }
        guard Set(ordered.map(\.origin)).count == 1 else { return try unavailable("Recovery requires one sample origin") }
        guard toleranceSeconds.isFinite, toleranceSeconds >= 0,
              toleranceSeconds <= Double(UInt64.max) / 1_000_000_000 else {
            throw MetricsInputError.invalidConfiguration
        }
        let toleranceNanoseconds = UInt64(toleranceSeconds * 1_000_000_000)
        guard let start = ordered.filter({ $0.receivedMonotonicNanoseconds <= exerciseEndedMonotonicNanoseconds &&
            exerciseEndedMonotonicNanoseconds - $0.receivedMonotonicNanoseconds <= 5_000_000_000 }).last else {
            return try unavailable("No heart-rate sample near exercise end")
        }
        let (targetMonotonic, targetOverflow) = exerciseEndedMonotonicNanoseconds.addingReportingOverflow(60_000_000_000)
        let (windowEnd, windowOverflow) = targetMonotonic.addingReportingOverflow(toleranceNanoseconds)
        guard !targetOverflow, !windowOverflow else { throw MetricsInputError.invalidConfiguration }
        let recoveryEndUTC = exerciseEndedAtUTC.addingTimeInterval(60 + toleranceSeconds)
        guard !interruptions.contains(where: { marker in
            let end = marker.endedAtUTC ?? recoveryEndUTC
            return marker.startedAtUTC <= recoveryEndUTC && end >= exerciseEndedAtUTC
        }) else { return try unavailable("Recovery window intersects a recorded interruption") }
        let recoveryWindow = ordered.filter { $0.receivedMonotonicNanoseconds >= exerciseEndedMonotonicNanoseconds &&
            $0.receivedMonotonicNanoseconds <= windowEnd }
        guard let first = recoveryWindow.first,
              first.receivedMonotonicNanoseconds - exerciseEndedMonotonicNanoseconds <= 2_000_000_000,
              let last = recoveryWindow.last,
              last.receivedMonotonicNanoseconds - exerciseEndedMonotonicNanoseconds >= 55_000_000_000,
              recoveryWindow.count >= 50 else { return try unavailable("Recovery coverage is incomplete") }
        guard zip(recoveryWindow, recoveryWindow.dropFirst()).allSatisfy({ pair in
                  pair.1.receivedMonotonicNanoseconds >= pair.0.receivedMonotonicNanoseconds &&
                  pair.1.receivedMonotonicNanoseconds - pair.0.receivedMonotonicNanoseconds <= 3_000_000_000
              }), let recovery = recoveryWindow.min(by: {
                  absoluteDifference($0.receivedMonotonicNanoseconds, targetMonotonic) <
                  absoluteDifference($1.receivedMonotonicNanoseconds, targetMonotonic)
              }), absoluteDifference(recovery.receivedMonotonicNanoseconds, targetMonotonic) <= toleranceNanoseconds else {
            return try unavailable("Recovery stream contains a gap longer than three seconds")
        }
        let detail = RecoveryResult(startBPM: start.beatsPerMinute, recoveryBPM: recovery.beatsPerMinute,
                                    dropBPM: start.beatsPerMinute - recovery.beatsPerMinute,
                                    mode: mode, coveredSamples: recoveryWindow.count)
        return .init(metric: try MetricResult(id: "heart_rate_recovery_1m", name: "One-minute heart-rate recovery",
                     value: Double(detail.dropBPM), unit: "bpm", classification: .calculated,
                     context: .exerciseSession, lineage: lineage, algorithmVersion: "recovery-v1",
                     configurationVersion: "\(mode.rawValue)-60s-v1", quality: .good, reasons: []), detail: detail)
    }

    private static func absoluteDifference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

struct ReadinessConfiguration: Codable, Equatable, Sendable {
    let version: String
    let baselineWindowDays: Int
    let minimumValidDays: Int
    let lnRMSSDWeight: Double
    let restingHRWeight: Double
    let restingHRDispersionFloor: Double
    let lnRMSSDDispersionFloor: Double
    let maximumAbsoluteZScore: Double
    static let v1 = Self(version: "readiness-v1", baselineWindowDays: 28, minimumValidDays: 14,
                         lnRMSSDWeight: 8, restingHRWeight: 8, restingHRDispersionFloor: 2,
                         lnRMSSDDispersionFloor: 0.10, maximumAbsoluteZScore: 3)
}

struct ReadinessInput: Equatable, Sendable {
    let dayUTC: Date
    let restingHeartRate: Double
    let lnRMSSD: Double
    let origin: SampleOrigin
    let purpose: MeasurementPurpose
    let state: SessionState
    let durationSeconds: Double
    let interruptionCount: Int
    let quality: DataQualityLevel
    let timeZoneIdentifier: String

    init(dayUTC: Date, restingHeartRate: Double, lnRMSSD: Double, origin: SampleOrigin,
         purpose: MeasurementPurpose, state: SessionState, durationSeconds: Double,
         interruptionCount: Int, quality: DataQualityLevel,
         timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.dayUTC = dayUTC; self.restingHeartRate = restingHeartRate; self.lnRMSSD = lnRMSSD
        self.origin = origin; self.purpose = purpose; self.state = state; self.durationSeconds = durationSeconds
        self.interruptionCount = interruptionCount; self.quality = quality
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    var isEligible: Bool {
        origin == .polarH9 && purpose == .restingCheckIn && state == .completed && durationSeconds >= 180 &&
        interruptionCount == 0 && (quality == .good || quality == .fair) &&
        restingHeartRate.isFinite && lnRMSSD.isFinite
    }
}
struct ReadinessEstimate: Equatable, Sendable {
    let score: Int?
    let baselineDays: Int
    let classification: MetricClassification
    let confidence: DataQualityLevel
    let reasons: [String]
    let algorithmVersion: String
    let metric: MetricResult
    let evidence: ReadinessEvidence?
}
struct ReadinessEvidence: Equatable, Sendable {
    let restingHeartRateCenter: Double
    let lnRMSSDCenter: Double
    let restingHeartRateScale: Double
    let lnRMSSDScale: Double
    let restingHeartRateZScore: Double
    let lnRMSSDZScore: Double
}

enum ReadinessEngine {
    static func estimate(today: ReadinessInput, baseline: [ReadinessInput], previousScore: Int? = nil,
                         configuration: ReadinessConfiguration = .v1) throws -> ReadinessEstimate {
        guard configuration.baselineWindowDays > 0, configuration.minimumValidDays > 0,
              configuration.minimumValidDays <= configuration.baselineWindowDays,
              configuration.lnRMSSDWeight >= 0, configuration.restingHRWeight >= 0,
              configuration.restingHRDispersionFloor > 0, configuration.lnRMSSDDispersionFloor > 0,
              configuration.maximumAbsoluteZScore > 0,
              [configuration.lnRMSSDWeight, configuration.restingHRWeight,
               configuration.restingHRDispersionFloor, configuration.lnRMSSDDispersionFloor,
               configuration.maximumAbsoluteZScore].allSatisfy(\.isFinite) else {
            throw MetricsInputError.invalidConfiguration
        }
        let lineageFor: ([ReadinessInput]) -> MetricLineage = { MetricLineage(sampleOrigins: Set($0.map(\.origin))) }
        let unavailable: (String, Int, [ReadinessInput]) throws -> ReadinessEstimate = { reason, days, inputs in
            let metric = try MetricResult(id: "solar_readiness", name: "Solar Readiness", value: nil, unit: "score",
                classification: .unavailable, context: .restingCheckIn, lineage: lineageFor(inputs),
                algorithmVersion: configuration.version, configurationVersion: configuration.version,
                quality: .insufficient, reasons: [reason])
            return .init(score: nil, baselineDays: days, classification: .unavailable, confidence: .poor,
                         reasons: [reason], algorithmVersion: configuration.version, metric: metric, evidence: nil)
        }
        guard today.isEligible else {
            return try unavailable("Today's resting check-in is not eligible", 0, [today])
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: today.timeZoneIdentifier) else {
            throw MetricsInputError.invalidConfiguration
        }
        calendar.timeZone = timeZone
        let todayKey = calendar.startOfDay(for: today.dayUTC)
        let cutoff = calendar.date(byAdding: .day, value: -configuration.baselineWindowDays, to: todayKey)
            ?? todayKey.addingTimeInterval(Double(-configuration.baselineWindowDays) * 86_400)
        let prior = baseline.filter { $0.isEligible && $0.dayUTC < todayKey && $0.dayUTC >= cutoff }
            .sorted { $0.dayUTC > $1.dayUTC }
        var seenDays: Set<Date> = []
        let values = prior.filter { seenDays.insert(calendar.startOfDay(for: $0.dayUTC)).inserted }
        guard values.count >= configuration.minimumValidDays else {
            return try unavailable("Baseline building: \(values.count)/\(configuration.minimumValidDays) valid days",
                                   values.count, [today] + values)
        }
        let hr = values.map(\.restingHeartRate), lnr = values.map(\.lnRMSSD)
        let hrCenter = median(hr), lnCenter = median(lnr)
        let hrScale = max(configuration.restingHRDispersionFloor, 1.4826 * median(hr.map { abs($0 - hrCenter) }))
        let lnScale = max(configuration.lnRMSSDDispersionFloor, 1.4826 * median(lnr.map { abs($0 - lnCenter) }))
        let lnZ = min(configuration.maximumAbsoluteZScore,
                      max(-configuration.maximumAbsoluteZScore, (today.lnRMSSD - lnCenter) / lnScale))
        let hrZ = min(configuration.maximumAbsoluteZScore,
                      max(-configuration.maximumAbsoluteZScore, (today.restingHeartRate - hrCenter) / hrScale))
        let raw = 50 + configuration.lnRMSSDWeight * lnZ - configuration.restingHRWeight * hrZ
        let score = Int(min(100, max(0, raw)).rounded())
        var reasons: [String] = []
        if today.lnRMSSD < lnCenter - lnScale { reasons.append("lnRMSSD is below your recent baseline") }
        if today.restingHeartRate > hrCenter + hrScale { reasons.append("Resting heart rate is above your recent baseline") }
        if reasons.isEmpty { reasons.append("Inputs are near your recent personal baseline") }
        if let previousScore, abs(score - previousScore) >= 10 {
            reasons.append("Readiness changed materially from the previous eligible check-in")
        }
        let confidence: DataQualityLevel = values.count >= 21 && ([today] + values).allSatisfy { $0.quality == .good } ? .good : .fair
        if confidence == .fair { reasons.append("Confidence is limited by baseline length or input quality") }
        let metric = try MetricResult(id: "solar_readiness", name: "Solar Readiness", value: Double(score), unit: "score",
                                      classification: .estimated, context: .restingCheckIn,
                                      lineage: lineageFor([today] + values), algorithmVersion: configuration.version,
                                      configurationVersion: configuration.version, quality: confidence, reasons: reasons)
        let evidence = ReadinessEvidence(restingHeartRateCenter: hrCenter, lnRMSSDCenter: lnCenter,
                                         restingHeartRateScale: hrScale, lnRMSSDScale: lnScale,
                                         restingHeartRateZScore: hrZ, lnRMSSDZScore: lnZ)
        return .init(score: score, baselineDays: values.count, classification: .estimated, confidence: confidence,
                     reasons: reasons, algorithmVersion: configuration.version, metric: metric, evidence: evidence)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), m = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[m - 1] + sorted[m]) / 2 : sorted[m]
    }
}
