import Foundation

enum MetricClassification: String, Codable, Sendable {
    case measured
    case calculated
    case estimated
    case unavailable
}

enum DataQualityLevel: String, Codable, Sendable {
    case insufficient
    case poor
    case fair
    case good
}

struct MetricLineage: Codable, Equatable, Sendable {
    let sampleOrigins: Set<SampleOrigin>
    let includesUserInput: Bool

    init(sampleOrigins: Set<SampleOrigin>, includesUserInput: Bool = false) {
        self.sampleOrigins = sampleOrigins
        self.includesUserInput = includesUserInput
    }
}

enum MetricResultValidationError: Error, Equatable {
    case missingValue
    case unexpectedValue
    case nonFiniteValue
    case missingReason
    case invalidQualityForUnavailable
    case missingVersion
    case missingLineage
    case mixedRealAndSimulatedLineage
}

struct MetricResult: Identifiable, Encodable, Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let value: Double?
    let unit: String
    let classification: MetricClassification
    let context: MeasurementPurpose
    let lineage: MetricLineage
    let algorithmVersion: String
    let configurationVersion: String
    let quality: DataQualityLevel
    let reasons: [String]

    init(
        id: String,
        name: String,
        value: Double?,
        unit: String,
        classification: MetricClassification,
        context: MeasurementPurpose,
        lineage: MetricLineage,
        algorithmVersion: String,
        configurationVersion: String,
        quality: DataQualityLevel,
        reasons: [String]
    ) throws {
        if algorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            configurationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MetricResultValidationError.missingVersion
        }
        if lineage.sampleOrigins.contains(.polarH9) && lineage.sampleOrigins.contains(.simulator) {
            throw MetricResultValidationError.mixedRealAndSimulatedLineage
        }
        if classification != .unavailable && lineage.sampleOrigins.isEmpty && !lineage.includesUserInput {
            throw MetricResultValidationError.missingLineage
        }
        if quality != .good && !reasons.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw MetricResultValidationError.missingReason
        }
        if classification == .unavailable {
            guard value == nil else { throw MetricResultValidationError.unexpectedValue }
            guard quality != .good else { throw MetricResultValidationError.invalidQualityForUnavailable }
        } else {
            guard let value else { throw MetricResultValidationError.missingValue }
            guard value.isFinite else { throw MetricResultValidationError.nonFiniteValue }
        }

        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.classification = classification
        self.context = context
        self.lineage = lineage
        self.algorithmVersion = algorithmVersion
        self.configurationVersion = configurationVersion
        self.quality = quality
        self.reasons = reasons
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, value, unit, classification, context, lineage
        case algorithmVersion, configurationVersion, quality, reasons
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: values.decode(String.self, forKey: .id),
                name: values.decode(String.self, forKey: .name),
                value: values.decodeIfPresent(Double.self, forKey: .value),
                unit: values.decode(String.self, forKey: .unit),
                classification: values.decode(MetricClassification.self, forKey: .classification),
                context: values.decode(MeasurementPurpose.self, forKey: .context),
                lineage: values.decode(MetricLineage.self, forKey: .lineage),
                algorithmVersion: values.decode(String.self, forKey: .algorithmVersion),
                configurationVersion: values.decode(String.self, forKey: .configurationVersion),
                quality: values.decode(DataQualityLevel.self, forKey: .quality),
                reasons: values.decode([String].self, forKey: .reasons)
            )
        } catch let error as MetricResultValidationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid metric result: \(error)"))
        }
    }
}
