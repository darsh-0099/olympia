import Foundation

enum HeartRateMeasurementParseError: Error, Equatable {
    case truncated(field: String)
    case reservedFlagsSet(UInt8)
    case trailingByte
}

struct ParsedHeartRateMeasurement: Equatable, Sendable {
    let rawFlags: UInt8
    let beatsPerMinute: UInt16
    let sensorContactSupported: Bool
    let sensorContactDetected: Bool?
    let energyExpended: UInt16?
    let rrIntervalTicks1024: [UInt16]
}

enum HeartRateMeasurementParser {
    /// Parses the Bluetooth SIG Heart Rate Measurement layout in little-endian
    /// field order. RFU flag bits are rejected so an unknown future layout is
    /// never silently misaligned. Physiologic plausibility is assessed later;
    /// every raw RR tick value is preserved here.
    static func parse(_ data: Data) throws -> ParsedHeartRateMeasurement {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { throw HeartRateMeasurementParseError.truncated(field: "flags") }
        let reserved = flags & 0b1110_0000
        guard reserved == 0 else { throw HeartRateMeasurementParseError.reservedFlagsSet(reserved) }

        var cursor = 1
        func require(_ count: Int, field: String) throws {
            guard cursor + count <= bytes.count else {
                throw HeartRateMeasurementParseError.truncated(field: field)
            }
        }
        func readUInt8(field: String) throws -> UInt8 {
            try require(1, field: field)
            defer { cursor += 1 }
            return bytes[cursor]
        }
        func readUInt16(field: String) throws -> UInt16 {
            try require(2, field: field)
            defer { cursor += 2 }
            return UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
        }

        let isUInt16HeartRate = flags & 0x01 != 0
        let heartRate = isUInt16HeartRate
            ? try readUInt16(field: "heartRate16")
            : UInt16(try readUInt8(field: "heartRate8"))

        let contactSupported = flags & 0x04 != 0
        let contactDetected = contactSupported ? flags & 0x02 != 0 : nil
        let energy = flags & 0x08 != 0 ? try readUInt16(field: "energyExpended") : nil

        var rrValues: [UInt16] = []
        if flags & 0x10 != 0 {
            guard bytes.count - cursor >= 2 else {
                throw HeartRateMeasurementParseError.truncated(field: "rrInterval")
            }
            guard (bytes.count - cursor).isMultiple(of: 2) else {
                throw HeartRateMeasurementParseError.trailingByte
            }
            while cursor < bytes.count {
                rrValues.append(try readUInt16(field: "rrInterval"))
            }
        } else if cursor != bytes.count {
            throw HeartRateMeasurementParseError.trailingByte
        }

        return ParsedHeartRateMeasurement(
            rawFlags: flags,
            beatsPerMinute: heartRate,
            sensorContactSupported: contactSupported,
            sensorContactDetected: contactDetected,
            energyExpended: energy,
            rrIntervalTicks1024: rrValues
        )
    }
}

enum HeartRateMeasurementTimestamping {
    /// HRS transmits multiple RR intervals oldest-to-newest. The newest interval
    /// ends at the notification receive time; earlier end times are reconstructed
    /// by subtracting only later intervals and are explicitly marked derived.
    static func rrSamples(
        from measurement: ParsedHeartRateMeasurement,
        receivedAtUTC: Date,
        monotonicNanoseconds: UInt64,
        origin: SampleOrigin
    ) -> [RRIntervalValue] {
        var laterDurationMilliseconds = 0.0
        var reversed: [RRIntervalValue] = []
        for ticks in measurement.rrIntervalTicks1024.reversed() {
            let beatTime = receivedAtUTC.addingTimeInterval(-laterDurationMilliseconds / 1_000)
            let offsetNanoseconds = UInt64((laterDurationMilliseconds * 1_000_000).rounded())
            reversed.append(
                RRIntervalValue(
                    rawTicks1024: ticks,
                    receivedAtUTC: receivedAtUTC,
                    receivedMonotonicNanoseconds: monotonicNanoseconds,
                    derivedBeatTimeUTC: beatTime,
                    derivedBeatMonotonicNanoseconds: monotonicNanoseconds >= offsetNanoseconds
                        ? monotonicNanoseconds - offsetNanoseconds
                        : nil,
                    origin: origin
                )
            )
            laterDurationMilliseconds += Double(ticks) * 1_000 / 1_024
        }
        return reversed.reversed()
    }
}
