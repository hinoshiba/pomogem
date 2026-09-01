import Observation
import SwiftUI
import UIKit

enum AppTab: Hashable {
    case jar
    case log
    case settings
}

enum PaywallPendingIntent: Equatable {
    case homeCustomDuration
}

enum ShareScope: Equatable {
    case all
    case month(Date)
    case aggregate(id: UUID, monthLabel: String)

    func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        switch self {
        case .all:
            return true
        case let .month(monthStart):
            return calendar.dateInterval(of: .month, for: monthStart)?.contains(date) ?? false
        case .aggregate:
            // Aggregate membership is ID-based and cannot be inferred from a date.
            return false
        }
    }

    var periodLabel: String {
        switch self {
        case .all:
            return Date.now.formatted(.dateTime.year().month().day())
        case let .month(monthStart):
            return StrataMath.monthLabel(for: monthStart)
        case let .aggregate(_, monthLabel):
            return monthLabel
        }
    }
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .jar
    var toast: ToastMessage?
    var paywallPresented = false
    var paywallContext: PaywallContext = .settings
    private(set) var pendingPaywallIntent: PaywallPendingIntent?
    private(set) var homeCustomDurationResumeRequested = false
    var sharePresented = false
    var shareScope: ShareScope = .all
    var recoveredFocus: RecoveredFocusRequest?
    var deferredFocusRecovery: RecoveredFocusRequest?
    var recoveredBreak: BreakRecoveryEnvelope?
    var cloudFocusRecoveryOffer: CloudFocusRecoveryOffer?

    /// The currently rendered bottle is retained so share cards can capture the exact
    /// SpriteKit composition instead of approximating it with a second layout engine.
    @ObservationIgnored
    var jarScene: JarScene?

    @ObservationIgnored
    private var toastTask: Task<Void, Never>?

    func showToast(_ text: String, symbol: String? = nil, duration: Duration = .seconds(3)) {
        toastTask?.cancel()
        let appearsAnimation: Animation? = UIAccessibility.isReduceMotionEnabled
            ? nil
            : .spring(response: 0.36, dampingFraction: 0.84)
        withAnimation(appearsAnimation) {
            toast = ToastMessage(text: text, symbol: symbol)
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.2)) {
                    self?.toast = nil
                }
            }
        }
    }

    func presentPaywall(
        from context: PaywallContext,
        pendingIntent: PaywallPendingIntent? = nil
    ) {
        paywallContext = context
        pendingPaywallIntent = pendingIntent
        paywallPresented = true
    }

    func resolvePaywallDismissal(isPro: Bool) {
        let intent = pendingPaywallIntent
        pendingPaywallIntent = nil

        guard isPro, intent == .homeCustomDuration else { return }
        homeCustomDurationResumeRequested = true
    }

    func consumeHomeCustomDurationResumeRequest() -> Bool {
        guard homeCustomDurationResumeRequested else { return false }
        homeCustomDurationResumeRequested = false
        return true
    }

    func presentShare(scope: ShareScope = .all) {
        shareScope = scope
        sharePresented = true
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let symbol: String?
}

struct ToastOverlay: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(TsumibenTheme.amber)
            }
            Text(message.text)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(TsumibenTheme.text)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(TsumibenTheme.amber.opacity(0.28), lineWidth: 1) }
        .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: message.text)
        }
    }
}

struct RecoveredFocusRequest: Identifiable {
    let id: UUID
    let subject: Subject?
    let subjectSnapshot: FocusSubjectSnapshot
    let engine: PomodoroEngine
    let clockAnchor: ClockAnchor?
    let pendingCompletion: PomodoroCompletion?
    let dataEpochID: UUID?
    let origin: FocusRecoveryOrigin
    let allowsLocalNotifications: Bool

    init(
        subject: Subject?,
        subjectSnapshot: FocusSubjectSnapshot,
        engine: PomodoroEngine,
        clockAnchor: ClockAnchor?,
        pendingCompletion: PomodoroCompletion? = nil,
        dataEpochID: UUID? = nil,
        origin: FocusRecoveryOrigin = .local,
        allowsLocalNotifications: Bool = true
    ) {
        id = pendingCompletion?.sessionID ?? engine.currentSessionID ?? UUID()
        self.subject = subject
        self.subjectSnapshot = subjectSnapshot
        self.engine = engine
        self.clockAnchor = clockAnchor
        self.pendingCompletion = pendingCompletion
        self.dataEpochID = dataEpochID
        self.origin = origin
        self.allowsLocalNotifications = allowsLocalNotifications
    }
}

enum FocusRecoveryOrigin: Equatable, Sendable {
    case local
    case iCloud
}

struct CloudFocusRecoveryOffer: Identifiable {
    let id: UUID
    let request: RecoveredFocusRequest

    init(request: RecoveredFocusRequest) {
        id = request.id
        self.request = request
    }
}
