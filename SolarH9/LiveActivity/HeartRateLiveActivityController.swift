@preconcurrency import ActivityKit
import Foundation

@MainActor
final class HeartRateLiveActivityController {
    private var activity: Activity<HeartRateActivityAttributes>?
    private var pulse = false
    private var lastState: HeartRateActivityAttributes.ContentState?
    private var reduceMotion = false

    var isActive: Bool { activity != nil }

    func configureReducedMotion(_ value: Bool) { reduceMotion = value }

    func start(
        activityID: UUID,
        startedAt: Date,
        mode: HeartRateActivityAttributes.Mode,
        origin: SampleOrigin,
        beatsPerMinute: Int?,
        averageBeatsPerMinute: Int?,
        zone: Int?,
        targetZone: Int?,
        connectionQuality: HeartRateActivityAttributes.ContentState.ConnectionQuality
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity, activity.attributes.activityID != activityID {
            await end()
        } else if activity != nil {
            await update(beatsPerMinute: beatsPerMinute, averageBeatsPerMinute: averageBeatsPerMinute,
                         phase: .recording, zone: zone, targetZone: targetZone,
                         connectionQuality: connectionQuality)
            return
        }

        let attributes = HeartRateActivityAttributes(
            activityID: activityID,
            startedAt: startedAt,
            mode: mode,
            isSimulated: origin == .simulator
        )
        let state = makeState(beatsPerMinute: beatsPerMinute, averageBeatsPerMinute: averageBeatsPerMinute,
                              phase: .recording, zone: zone, targetZone: targetZone,
                              connectionQuality: connectionQuality)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(8)),
                pushType: nil
            )
            lastState = state
        } catch {
            activity = nil
            lastState = nil
        }
    }

    func update(
        beatsPerMinute: Int?,
        averageBeatsPerMinute: Int?,
        phase: HeartRateActivityAttributes.ContentState.Phase,
        zone: Int?,
        targetZone: Int?,
        connectionQuality: HeartRateActivityAttributes.ContentState.ConnectionQuality
    ) async {
        guard let activity else { return }
        let state = makeState(
            beatsPerMinute: beatsPerMinute,
            averageBeatsPerMinute: averageBeatsPerMinute,
            phase: phase, zone: zone, targetZone: targetZone, connectionQuality: connectionQuality
        )
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(8)))
        lastState = state
    }

    func end() async {
        guard let activity else { return }
        let finalState = makeState(
            beatsPerMinute: lastState?.beatsPerMinute,
            averageBeatsPerMinute: lastState?.averageBeatsPerMinute,
            phase: .saving,
            zone: lastState?.zone,
            targetZone: lastState?.targetZone,
            connectionQuality: lastState?.connectionQuality ?? .disconnected
        )
        await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        self.activity = nil
        lastState = nil
    }

    func endOrphanedActivities() async {
        for existing in Activity<HeartRateActivityAttributes>.activities where existing.id != activity?.id {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func makeState(
        beatsPerMinute: Int?,
        averageBeatsPerMinute: Int?,
        phase: HeartRateActivityAttributes.ContentState.Phase,
        zone: Int?,
        targetZone: Int?,
        connectionQuality: HeartRateActivityAttributes.ContentState.ConnectionQuality
    ) -> HeartRateActivityAttributes.ContentState {
        pulse.toggle()
        return .init(
            beatsPerMinute: beatsPerMinute,
            averageBeatsPerMinute: averageBeatsPerMinute,
            phase: phase,
            updatedAt: Date(),
            pulse: pulse,
            zone: zone,
            targetZone: targetZone,
            connectionQuality: connectionQuality,
            reduceMotion: reduceMotion
        )
    }
}
