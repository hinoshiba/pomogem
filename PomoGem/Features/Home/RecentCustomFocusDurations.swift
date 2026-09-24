import Foundation

/// Up to three Pro custom focus durations this device used most recently,
/// newest first, so a Pro user who alternates between, say, 50 and 25 minutes
/// gets back to 50 with one tap instead of retyping it after every preset.
///
/// Home and Settings keep a single preferred duration, which a preset
/// replaces. This list is device-local UI state in UserDefaults, stored as a
/// short comma-separated string of seconds: it is not a synced `Prefs` field
/// (so the CloudKit schema in Docs/ProTimerPrecision.md is unchanged) and it
/// is not part of the JSON export. Values are re-validated on every read.
enum RecentCustomFocusDurations {
    static let storageKey = "focus.recent-custom-seconds.v1"
    static let maximumCount = 3

    /// Only a valid duration that is not one of the free presets is a
    /// custom duration worth remembering.
    static func isEligible(_ seconds: Int) -> Bool {
        let duration = PomodoroDuration(totalSeconds: seconds)
        return duration.isValid && duration.requiresPro
    }

    static func decode(_ rawValue: String) -> [Int] {
        var result: [Int] = []
        for part in rawValue.split(separator: ",") {
            guard let seconds = Int(part.trimmingCharacters(in: .whitespaces)),
                  isEligible(seconds),
                  !result.contains(seconds) else { continue }
            result.append(seconds)
            if result.count == maximumCount { break }
        }
        return result
    }

    static func encode(_ seconds: [Int]) -> String {
        seconds.map(String.init).joined(separator: ",")
    }

    /// Moves `seconds` to the front. Anything that is not an eligible custom
    /// duration leaves the list as it was.
    static func recording(_ seconds: Int, in rawValue: String) -> String {
        guard isEligible(seconds) else { return rawValue }
        let existing = decode(rawValue).filter { $0 != seconds }
        return encode(Array(([seconds] + existing).prefix(maximumCount)))
    }

    /// For screens without an `@AppStorage` binding (Settings); Home observes
    /// the same key and updates on its own.
    static func record(_ seconds: Int, defaults: UserDefaults = .standard) {
        let key = AccountScopedLocalState.defaultsKey(base: storageKey, defaults: defaults)
        let current = defaults.string(forKey: key) ?? ""
        let updated = recording(seconds, in: current)
        if updated != current { defaults.set(updated, forKey: key) }
    }
}
