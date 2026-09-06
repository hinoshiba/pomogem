import Foundation

enum AnalyticsEvent: String, CaseIterable, Codable, Sendable {
    case pomodoroComplete = "pomodoro_complete"
    case drop
    case gold
    case shareCreated = "share_created"
    case paywallView = "paywall_view"
    case purchase
}

protocol AnalyticsTracking: Sendable {
    func track(_ event: AnalyticsEvent, properties: [String: String])
}

extension AnalyticsTracking {
    func track(_ event: AnalyticsEvent) {
        track(event, properties: [:])
    }
}

/// Intentionally performs no persistence, networking or logging. Keeping the
/// seam lets features describe product events while v1 truthfully collects no
/// analytics data.
struct NoOpAnalytics: AnalyticsTracking {
    func track(_ event: AnalyticsEvent, properties: [String: String] = [:]) {}
}

enum Analytics {
    static let shared: any AnalyticsTracking = NoOpAnalytics()
}
