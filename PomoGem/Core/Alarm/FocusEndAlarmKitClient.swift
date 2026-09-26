import Foundation
#if canImport(AlarmKit)
import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
#endif

enum FocusEndAlarmClientFactory {
    /// The AlarmKit client on iOS 26 or later, otherwise a client that
    /// reports `.unsupported` and never schedules anything.
    @MainActor
    static func live() -> FocusEndAlarmClient {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return AlarmKitFocusEndAlarmClient()
        }
        #endif
        return UnsupportedFocusEndAlarmClient()
    }
}

#if canImport(AlarmKit)
/// No per-alarm data: the alert is account-neutral (no theme, no subject,
/// no gem), like the completion notification.
@available(iOS 26.0, *)
struct FocusEndAlarmMetadata: AlarmMetadata {}

/// The alarm's secondary button. It only brings PomoGem to the front; the
/// timer screen then resolves the completion and acknowledges the alarm.
/// Hidden from Shortcuts and Spotlight.
@available(iOS 26.0, *)
struct OpenPomoGemFromAlarmIntent: LiveActivityIntent {
    static let title = LocalizedStringResource(
        "アプリを開く",
        table: "Focus",
        comment: "Button on the system alarm at the end of a focus or break; opens PomoGem. Suggested English: Open App"
    )
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// The live AlarmKit boundary: one alert-only alarm at a fixed date. There
/// is deliberately no countdown or paused presentation, so AlarmKit needs no
/// widget Live Activity and none appears next to the focus Live Activity.
/// The stop button is the system's; `stopIntent` stays nil, so stopping
/// launches no app code.
@available(iOS 26.0, *)
@MainActor
final class AlarmKitFocusEndAlarmClient: FocusEndAlarmClient {
    private var manager: AlarmManager { AlarmManager.shared }

    var authorization: AlarmKitAuthorization {
        Self.authorization(manager.authorizationState)
    }

    func requestAuthorization() async -> AlarmKitAuthorization {
        do {
            return Self.authorization(try await manager.requestAuthorization())
        } catch {
            return authorization
        }
    }

    func schedule(_ request: FocusEndAlarmRequest) async throws {
        let attributes = AlarmAttributes<FocusEndAlarmMetadata>(
            presentation: AlarmPresentation(alert: Self.alert(for: request.phase)),
            metadata: FocusEndAlarmMetadata(),
            tintColor: Color(red: 0.910, green: 0.706, blue: 0.290)
        )
        let sound: AlertConfiguration.AlertSound = request.soundFileName
            .map { AlertConfiguration.AlertSound.named($0) } ?? .default
        let configuration = AlarmManager.AlarmConfiguration<FocusEndAlarmMetadata>.alarm(
            schedule: .fixed(request.fireDate),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: OpenPomoGemFromAlarmIntent(),
            sound: sound
        )
        _ = try await manager.schedule(id: request.alarmID, configuration: configuration)
    }

    func cancel(id: UUID) throws {
        try manager.cancel(id: id)
    }

    func stop(id: UUID) throws {
        try manager.stop(id: id)
    }

    func alarms() throws -> [FocusEndAlarmSnapshot] {
        try manager.alarms.map { alarm in
            let state: FocusEndAlarmSnapshot.State
            switch alarm.state {
            case .scheduled: state = .scheduled
            case .alerting: state = .alerting
            case .countdown, .paused: state = .other
            @unknown default: state = .other
            }
            return FocusEndAlarmSnapshot(id: alarm.id, state: state)
        }
    }

    private static func authorization(
        _ state: AlarmManager.AuthorizationState
    ) -> AlarmKitAuthorization {
        switch state {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    private static func alert(for phase: FocusEndAlarmPhase) -> AlarmPresentation.Alert {
        let title: LocalizedStringResource = switch phase {
        case .focus:
            LocalizedStringResource("集中時間が終わりました", table: "Focus", comment: "Title of the system alarm when a focus ends. Suggested English: Focus time is over")
        case .breakTime:
            LocalizedStringResource("休憩が終わりました", table: "Focus", comment: "Title of the system alarm when a break ends. Suggested English: Break is over")
        }
        let openApp = AlarmButton(
            text: LocalizedStringResource("アプリを開く", table: "Focus", comment: "Button on the system alarm at the end of a focus or break; opens PomoGem. Suggested English: Open App"),
            textColor: .white,
            systemImageName: "arrow.up.forward.app"
        )
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(
                title: title,
                secondaryButton: openApp,
                secondaryButtonBehavior: .custom
            )
        }
        return AlarmPresentation.Alert(
            title: title,
            stopButton: AlarmButton(
                text: LocalizedStringResource("止める", table: "Focus", comment: "Stop button on the system alarm (iOS 26.0 only). Suggested English: Stop"),
                textColor: .white,
                systemImageName: "stop.circle"
            ),
            secondaryButton: openApp,
            secondaryButtonBehavior: .custom
        )
    }
}
#endif
