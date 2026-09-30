#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// F5 UI-test evidence that a timer screen holds the display while its
/// completion alarm rings and lets it go when the alarm stops, read from
/// `UIApplication.isIdleTimerDisabled` itself. Active only with the in-memory
/// UI-test launch and `POMOGEM_UI_TEST_SCREEN_AWAKE_PROBE`:
///
/// - `1`: observe only;
/// - `magic-tap`: also perform the timer screen's Magic Tap two seconds after
///   an alarm starts ringing. XCUITest cannot perform that VoiceOver gesture;
///   this runs the same handler `.accessibilityAction(.magicTap)` runs.
///
/// The ledger samples every 50 ms for the whole process, so what it saw while
/// the focus screen was up is still there after that screen closes (0.35 s
/// after Stop): the next timer screen, the break a test starts from the
/// reward, shows it too.
@MainActor
final class TimerScreenAwakeUITestLedger {
    static let environmentKey = "POMOGEM_UI_TEST_SCREEN_AWAKE_PROBE"
    static let magicTapNotification = Notification.Name("PomoGem.UITest.timerMagicTap")
    static let magicTapDelay: TimeInterval = 2

    static let shared: TimerScreenAwakeUITestLedger? = {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = ProcessInfo.processInfo.environment[environmentKey],
              value == "1" || value == "magic-tap" else { return nil }
        return TimerScreenAwakeUITestLedger(performsMagicTap: value == "magic-tap")
    }()

    private let performsMagicTap: Bool
    private var timer: Timer?
    private var awake = false
    private var ringing = false
    private var ringStartedAt: TimeInterval?
    private var didMagicTap = false
    /// Samples taken while an alarm rang, and how many of them found the
    /// display held.
    private var ringingSamples = 0
    private var ringingAwakeSamples = 0
    /// Alarms that stopped (Stop, Magic Tap, leaving, the automatic stop),
    /// by whether the first sample afterwards found the display released.
    private var stopsReleased = 0
    private var stopsHeld = 0
    private var magicTaps = 0

    private init(performsMagicTap: Bool) {
        self.performsMagicTap = performsMagicTap
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var summary: String {
        "awake=\(awake ? 1 : 0);ringing=\(ringing ? 1 : 0);"
            + "ringingSamples=\(ringingSamples);ringingAwake=\(ringingAwakeSamples);"
            + "stopsReleased=\(stopsReleased);stopsHeld=\(stopsHeld);magicTaps=\(magicTaps)"
    }

    private func sample() {
        let alert = TimerCompletionAlertController.shared
        let isRinging = alert.activeConfiguration.map {
            alert.isRinging(sessionID: $0.sessionID)
        } ?? false
        awake = UIApplication.shared.isIdleTimerDisabled
        let uptime = ProcessInfo.processInfo.systemUptime
        if isRinging {
            if !ringing {
                ringStartedAt = uptime
                didMagicTap = false
            }
            ringingSamples += 1
            if awake { ringingAwakeSamples += 1 }
            if performsMagicTap, !didMagicTap,
               let ringStartedAt, uptime - ringStartedAt >= Self.magicTapDelay {
                didMagicTap = true
                magicTaps += 1
                NotificationCenter.default.post(name: Self.magicTapNotification, object: nil)
            }
        } else if ringing {
            if awake { stopsHeld += 1 } else { stopsReleased += 1 }
            ringStartedAt = nil
        }
        ringing = isRinging
    }
}

/// Shows `TimerScreenAwakeUITestLedger.summary` as the accessibility value
/// of `timer.screen-awake.probe`; nothing at all without the launch switch.
struct TimerScreenAwakeUITestProbe: View {
    @State private var value = ""

    var body: some View {
        if let ledger = TimerScreenAwakeUITestLedger.shared {
            Text("Timer screen awake probe")
                .font(.system(size: 1))
                .foregroundStyle(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("timer.screen-awake.probe")
                .accessibilityLabel("Timer screen awake probe")
                .accessibilityValue(Text(verbatim: value))
                .allowsHitTesting(false)
                .task {
                    while !Task.isCancelled {
                        value = ledger.summary
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
        }
    }
}
#endif
